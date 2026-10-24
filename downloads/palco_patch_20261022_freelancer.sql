-- Palco — patch de equipe e freelancer (22/10/2026)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez. Não apaga tabela, não trunca e não dá DELETE sem filtro.
--
-- O cargo visualizador passa a se chamar freelancer.
-- O administrador remove um membro pela função remove_company_member
-- (não apaga o usuário do Auth: isso exigiria a service role, que não fica no app).
-- O nome já gravado no evento e na OS permanece.
-- Convite de freelancer é outro código, sem senha. Bloqueio, revogação e validade
-- são checados em toda leitura.

SELECT set_config('app.bypass_tenant', 'on', false);

-- ---------------------------------------------------------------------------
-- Papel
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'profiles'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%visualizador%'
  LOOP
    EXECUTE format('ALTER TABLE profiles DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
UPDATE profiles SET role = 'freelancer' WHERE role = 'visualizador';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_role_check'
  ) THEN
    ALTER TABLE profiles
      ADD CONSTRAINT profiles_role_check
      CHECK (role IN (
        'admin', 'gerente', 'financeiro', 'estoque', 'tecnico', 'comercial', 'freelancer'
      ));
  END IF;
END $$;

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS freelancer_id uuid REFERENCES freelancers (id) ON DELETE SET NULL;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'role_price_visibility'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%visualizador%'
  LOOP
    EXECUTE format('ALTER TABLE role_price_visibility DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE role_price_visibility DROP CONSTRAINT IF EXISTS role_price_visibility_role_check;
UPDATE role_price_visibility
SET role = 'freelancer'
WHERE role = 'visualizador'
  AND NOT EXISTS (
    SELECT 1 FROM role_price_visibility other
    WHERE other.company_id = role_price_visibility.company_id
      AND other.role = 'freelancer'
  );
DELETE FROM role_price_visibility WHERE role = 'visualizador';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'role_price_visibility_role_check'
  ) THEN
    ALTER TABLE role_price_visibility
      ADD CONSTRAINT role_price_visibility_role_check
      CHECK (role IN (
        'admin', 'gerente', 'financeiro', 'estoque', 'tecnico', 'comercial', 'freelancer'
      ));
  END IF;
END $$;

INSERT INTO role_price_visibility (company_id, role, can_see_prices)
SELECT id, 'freelancer', false FROM companies
ON CONFLICT (company_id, role) DO UPDATE SET can_see_prices = false;

CREATE OR REPLACE FUNCTION lock_freelancer_price_flag()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.role = 'freelancer' AND NEW.can_see_prices THEN
    RAISE EXCEPTION 'Freelancer não vê valores';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_freelancer_price ON role_price_visibility;
CREATE TRIGGER trg_lock_freelancer_price
  BEFORE INSERT OR UPDATE ON role_price_visibility
  FOR EACH ROW EXECUTE FUNCTION lock_freelancer_price_flag();

CREATE OR REPLACE FUNCTION join_company(
  p_code text,
  p_full_name text,
  p_email text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_company uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE auth_subject = v_user) THEN
    RAISE EXCEPTION 'Usuário já vinculado a uma empresa';
  END IF;
  IF p_full_name IS NULL OR char_length(btrim(p_full_name)) < 2 THEN
    RAISE EXCEPTION 'Informe seu nome';
  END IF;
  SELECT id INTO v_company
  FROM companies
  WHERE invite_code = upper(btrim(COALESCE(p_code, '')));
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Código de convite inválido';
  END IF;
  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'freelancer');
  RETURN v_company;
END;
$$;

-- ---------------------------------------------------------------------------
-- Convites de acesso sem senha
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS freelancer_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  freelancer_id uuid NOT NULL REFERENCES freelancers (id) ON DELETE CASCADE,
  code text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9]{6,16}$'),
  expires_at timestamptz,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'blocked', 'revoked')),
  auth_subject text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS freelancer_invites_company_idx
  ON freelancer_invites (company_id, status);
CREATE INDEX IF NOT EXISTS freelancer_invites_freelancer_idx
  ON freelancer_invites (freelancer_id);

ALTER TABLE freelancer_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE freelancer_invites FORCE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_00_tenant ON freelancer_invites;
CREATE TRIGGER trg_00_tenant
  BEFORE INSERT OR UPDATE ON freelancer_invites
  FOR EACH ROW EXECUTE FUNCTION set_tenant_company();

DROP TRIGGER IF EXISTS trg_90_touch ON freelancer_invites;
CREATE TRIGGER trg_90_touch
  BEFORE UPDATE ON freelancer_invites
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION freelancer_session_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN current_app_role() IS DISTINCT FROM 'freelancer' THEN true
    WHEN NOT EXISTS (
      SELECT 1 FROM freelancer_invites WHERE auth_subject = current_jwt_sub()
    ) THEN true
    ELSE EXISTS (
      SELECT 1 FROM freelancer_invites i
      WHERE i.auth_subject = current_jwt_sub()
        AND i.status = 'active'
        AND (i.expires_at IS NULL OR i.expires_at > now())
    )
  END;
$$;

CREATE OR REPLACE FUNCTION freelancer_on_event(p_event uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM event_freelancers ef
    JOIN profiles p
      ON p.auth_subject = current_jwt_sub()
     AND p.active
     AND p.company_id = ef.company_id
    WHERE ef.event_id = p_event
      AND (
        (p.freelancer_id IS NOT NULL AND ef.freelancer_id = p.freelancer_id)
        OR (
          p.freelancer_id IS NULL
          AND lower(btrim(ef.name)) = lower(btrim(p.full_name))
        )
      )
  );
$$;

CREATE OR REPLACE FUNCTION freelancer_access_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT freelancer_session_ok();
$$;

CREATE OR REPLACE FUNCTION remove_company_member(p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid;
  v_role text;
  v_subject text;
  v_target_company uuid;
  v_target_role text;
  v_target_subject text;
  v_admins integer;
BEGIN
  SELECT company_id, role, auth_subject
    INTO v_company, v_role, v_subject
  FROM profiles
  WHERE auth_subject = current_jwt_sub()
    AND active;

  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Apenas o administrador remove uma conta';
  END IF;

  SELECT company_id, role, auth_subject
    INTO v_target_company, v_target_role, v_target_subject
  FROM profiles
  WHERE id = p_profile_id;

  IF v_target_company IS NULL OR v_target_company IS DISTINCT FROM v_company THEN
    RAISE EXCEPTION 'Conta de outra empresa';
  END IF;
  IF v_target_subject = v_subject THEN
    RAISE EXCEPTION 'Você não pode excluir a própria conta';
  END IF;
  IF v_target_role = 'admin' THEN
    SELECT count(*) INTO v_admins
    FROM profiles
    WHERE company_id = v_company
      AND role = 'admin'
      AND active;
    IF v_admins <= 1 THEN
      RAISE EXCEPTION 'A empresa precisa manter um administrador';
    END IF;
  END IF;

  UPDATE freelancer_invites
  SET status = 'revoked', updated_at = now()
  WHERE company_id = v_company
    AND auth_subject = v_target_subject
    AND status <> 'revoked';

  DELETE FROM profiles WHERE id = p_profile_id AND company_id = v_company;
END;
$$;

CREATE OR REPLACE FUNCTION create_freelancer_invite(
  p_freelancer_id uuid,
  p_expires_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid;
  v_code text;
  v_id uuid;
  v_try integer := 0;
BEGIN
  IF NOT has_role('admin', 'gerente') THEN
    RAISE EXCEPTION 'Apenas administrador ou gerente gera convite';
  END IF;
  v_company := current_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM freelancers WHERE id = p_freelancer_id AND company_id = v_company
  ) THEN
    RAISE EXCEPTION 'Freelancer de outra empresa';
  END IF;

  UPDATE freelancer_invites
  SET status = 'revoked', updated_at = now()
  WHERE freelancer_id = p_freelancer_id
    AND company_id = v_company
    AND status = 'active';

  LOOP
    v_try := v_try + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM freelancer_invites WHERE code = v_code);
    IF v_try > 8 THEN
      RAISE EXCEPTION 'Não foi possível gerar o código';
    END IF;
  END LOOP;

  INSERT INTO freelancer_invites (company_id, freelancer_id, code, expires_at, status)
  VALUES (v_company, p_freelancer_id, v_code, p_expires_at, 'active')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'code', v_code,
    'freelancer_id', p_freelancer_id,
    'expires_at', p_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION set_freelancer_invite_status(
  p_invite_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid := current_company_id();
BEGIN
  IF p_status NOT IN ('active', 'blocked', 'revoked') THEN
    RAISE EXCEPTION 'Status inválido';
  END IF;
  IF NOT has_role('admin', 'gerente') THEN
    RAISE EXCEPTION 'Apenas administrador ou gerente altera o convite';
  END IF;
  UPDATE freelancer_invites
  SET status = p_status, updated_at = now()
  WHERE id = p_invite_id
    AND company_id = v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Convite não encontrado';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION redeem_freelancer_invite(p_code text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_invite freelancer_invites%ROWTYPE;
  v_name text;
  v_email text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida';
  END IF;

  SELECT * INTO v_invite
  FROM freelancer_invites
  WHERE code = upper(btrim(COALESCE(p_code, '')));

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código inválido';
  END IF;
  IF v_invite.status = 'blocked' THEN
    RAISE EXCEPTION 'Este acesso está bloqueado';
  END IF;
  IF v_invite.status = 'revoked' THEN
    RAISE EXCEPTION 'Este acesso foi revogado';
  END IF;
  IF v_invite.expires_at IS NOT NULL AND v_invite.expires_at <= now() THEN
    RAISE EXCEPTION 'Este acesso expirou';
  END IF;
  IF EXISTS (
    SELECT 1 FROM profiles
    WHERE auth_subject = v_user
      AND company_id IS DISTINCT FROM v_invite.company_id
  ) THEN
    RAISE EXCEPTION 'Esta sessão já está em outra empresa';
  END IF;

  SELECT name INTO v_name FROM freelancers WHERE id = v_invite.freelancer_id;
  v_email := 'f.' || lower(v_invite.code) || '@convite.palco.app';

  IF v_invite.auth_subject IS NOT NULL AND v_invite.auth_subject IS DISTINCT FROM v_user THEN
    DELETE FROM profiles
    WHERE auth_subject = v_invite.auth_subject
      AND company_id = v_invite.company_id
      AND role = 'freelancer';
  END IF;

  INSERT INTO profiles (auth_subject, company_id, full_name, email, role, active, freelancer_id)
  VALUES (
    v_user,
    v_invite.company_id,
    COALESCE(NULLIF(btrim(v_name), ''), 'Freelancer'),
    v_email,
    'freelancer',
    true,
    v_invite.freelancer_id
  )
  ON CONFLICT (auth_subject) DO UPDATE
    SET full_name = EXCLUDED.full_name,
        email = EXCLUDED.email,
        role = 'freelancer',
        active = true,
        freelancer_id = EXCLUDED.freelancer_id;

  UPDATE freelancer_invites
  SET auth_subject = v_user, updated_at = now()
  WHERE id = v_invite.id;
END;
$$;

-- ---------------------------------------------------------------------------
-- RLS: freelancer só lê a própria agenda
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS profiles_select ON profiles;
CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (
    auth_subject = current_jwt_sub()
    OR (
      company_id = current_company_id()
      AND current_app_role() IS DISTINCT FROM 'freelancer'
    )
  );

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'equipment_categories', 'kits', 'kit_items', 'consumables',
    'maintenance_logs', 'purchase_needs', 'clients', 'quotes', 'quote_items',
    'stored_files', 'freelancers', 'vehicles', 'vehicle_maintenance',
    'role_price_visibility'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_select', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (company_id = current_company_id() AND current_app_role() IS DISTINCT FROM ''freelancer'')',
      t || '_select',
      t
    );
  END LOOP;
END $$;

DROP POLICY IF EXISTS events_select ON events;
CREATE POLICY events_select ON events
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(id))
    )
  );

DROP POLICY IF EXISTS event_allocations_select ON event_allocations;
CREATE POLICY event_allocations_select ON event_allocations
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(event_id))
    )
  );

DROP POLICY IF EXISTS event_freelancers_select ON event_freelancers;
CREATE POLICY event_freelancers_select ON event_freelancers
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(event_id))
    )
  );

DROP POLICY IF EXISTS event_transports_select ON event_transports;
CREATE POLICY event_transports_select ON event_transports
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(event_id))
    )
  );

DROP POLICY IF EXISTS equipment_items_select ON equipment_items;
CREATE POLICY equipment_items_select ON equipment_items
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR EXISTS (
        SELECT 1 FROM event_allocations a
        WHERE a.equipment_item_id = equipment_items.id
          AND freelancer_on_event(a.event_id)
          AND freelancer_session_ok()
      )
    )
  );

DROP POLICY IF EXISTS freelancer_invites_select ON freelancer_invites;
CREATE POLICY freelancer_invites_select ON freelancer_invites
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND has_role('admin', 'gerente')
  );

DROP POLICY IF EXISTS freelancer_invites_write ON freelancer_invites;
CREATE POLICY freelancer_invites_write ON freelancer_invites
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente'));

-- Valores mascarados na leitura usada pelo app. A policy acima já esconde
-- orçamento, financeiro e o catálogo. Diária e combustível do próprio evento
-- saem nulos para o papel freelancer.
CREATE OR REPLACE VIEW event_crew_visible
WITH (security_invoker = true) AS
SELECT
  id,
  company_id,
  event_id,
  freelancer_id,
  name,
  job_title,
  phone,
  days,
  notes,
  created_at,
  CASE
    WHEN current_app_role() = 'freelancer' THEN NULL
    ELSE daily_rate
  END AS daily_rate
FROM event_freelancers;

CREATE OR REPLACE VIEW event_trips_visible
WITH (security_invoker = true) AS
SELECT
  id,
  company_id,
  event_id,
  vehicle_id,
  plate,
  model,
  driver_name,
  distance_km,
  consumption_km_per_liter,
  notes,
  created_at,
  CASE WHEN current_app_role() = 'freelancer' THEN NULL ELSE fuel_price END AS fuel_price,
  CASE WHEN current_app_role() = 'freelancer' THEN NULL ELSE tolls END AS tolls,
  CASE WHEN current_app_role() = 'freelancer' THEN NULL ELSE other_cost END AS other_cost
FROM event_transports;

CREATE OR REPLACE VIEW freelancer_invite_gaps
WITH (security_invoker = true) AS
SELECT DISTINCT
  f.company_id,
  f.id AS freelancer_id,
  f.name AS freelancer_name,
  e.id AS event_id,
  e.title AS event_title
FROM event_freelancers ef
JOIN freelancers f ON f.id = ef.freelancer_id
JOIN events e ON e.id = ef.event_id
WHERE e.status NOT IN ('concluido', 'cancelado')
  AND NOT EXISTS (
    SELECT 1 FROM freelancer_invites i
    WHERE i.freelancer_id = f.id
      AND i.status = 'active'
      AND (i.expires_at IS NULL OR i.expires_at > now())
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON freelancer_invites TO authenticated;
GRANT SELECT ON event_crew_visible, event_trips_visible, freelancer_invite_gaps TO authenticated;

GRANT EXECUTE ON FUNCTION freelancer_session_ok() TO authenticated;
GRANT EXECUTE ON FUNCTION freelancer_on_event(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION freelancer_access_open() TO authenticated;
GRANT EXECUTE ON FUNCTION remove_company_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION create_freelancer_invite(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION set_freelancer_invite_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION redeem_freelancer_invite(text) TO authenticated;
GRANT EXECUTE ON FUNCTION join_company(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION lock_freelancer_price_flag() TO authenticated;
