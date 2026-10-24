-- Palco — tipos só do técnico e agenda individual (23/10/2026)
-- Cole só este arquivo no SQL Editor, depois de palco_patch_20261023_tipos_tecnico.sql.
-- Pode colar de novo. Não rode palco_supabase.sql.
-- Não apaga tabela, não dá TRUNCATE e não dá DELETE.
--
-- Migração dos tipos
-- O tipo único (tech_type) sai de administrador, gerente, financeiro, comercial e freelancer.
-- Quem é técnico guarda uma lista (tech_types): som, luz e/ou video.
-- Quem já era técnico e estava em Som continua Som, agora numa lista de um item.
-- Quem já era Luz ou Vídeo conserva esse tipo. Lista vazia de técnico vira Som.
-- Freelancer e os outros cargos ficam com a lista vazia.
-- No evento, a cópia do tipo (tech_types) só permanece quando o nome bate com um técnico
-- da mesma empresa e a linha não tem freelancer_id. Freelancer no evento fica sem tipo.
--
-- Migração da agenda
-- A caixa agenda_todos do cargo técnico deixa de valer.
-- Cada técnico ganha profiles.agenda_all.
-- Quem já tinha a caixa do cargo ligada nasce com a flag individual ligada.
-- Quem tinha a caixa desligada nasce com a flag desligada.
-- Freelancer não recebe essa flag: continua só nos eventos em que está selecionado.
-- Administrador, gerente, financeiro e comercial seguem a caixa do próprio cargo.
-- A caixa do cargo técnico é gravada como falsa para não brigar com a flag individual.
-- Rodar de novo não apaga uma flag que o administrador já editou (só preenche NULL).

SELECT set_config('app.bypass_tenant', 'on', false);

-- ---------------------------------------------------------------------------
-- Tipos: lista no perfil e cópia no evento
-- ---------------------------------------------------------------------------

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS tech_types text[] DEFAULT '{}';
UPDATE profiles SET tech_types = '{}' WHERE tech_types IS NULL;
ALTER TABLE profiles ALTER COLUMN tech_types SET DEFAULT '{}';
ALTER TABLE profiles ALTER COLUMN tech_types SET NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'tech_type'
  ) THEN
    UPDATE profiles
    SET tech_types = ARRAY[tech_type]::text[]
    WHERE role = 'tecnico'
      AND cardinality(tech_types) = 0
      AND tech_type IN ('som', 'luz', 'video');
  END IF;
END $$;

UPDATE profiles
SET tech_types = ARRAY(
  SELECT x FROM unnest(tech_types) AS x
  WHERE x IN ('som', 'luz', 'video')
)
WHERE EXISTS (
  SELECT 1 FROM unnest(tech_types) AS x
  WHERE x IS NULL OR x NOT IN ('som', 'luz', 'video')
);

UPDATE profiles
SET tech_types = ARRAY['som']::text[]
WHERE role = 'tecnico' AND cardinality(tech_types) = 0;

UPDATE profiles
SET tech_types = '{}'
WHERE role IS DISTINCT FROM 'tecnico';

ALTER TABLE event_freelancers ADD COLUMN IF NOT EXISTS tech_types text[] DEFAULT '{}';
UPDATE event_freelancers SET tech_types = '{}' WHERE tech_types IS NULL;
ALTER TABLE event_freelancers ALTER COLUMN tech_types SET DEFAULT '{}';
ALTER TABLE event_freelancers ALTER COLUMN tech_types SET NOT NULL;

UPDATE event_freelancers ef
SET tech_types = p.tech_types
FROM profiles p
WHERE ef.freelancer_id IS NULL
  AND cardinality(ef.tech_types) = 0
  AND p.company_id = ef.company_id
  AND p.role = 'tecnico'
  AND lower(btrim(p.full_name)) = lower(btrim(ef.name))
  AND cardinality(p.tech_types) > 0;

UPDATE event_freelancers
SET tech_types = '{}'
WHERE freelancer_id IS NOT NULL;

UPDATE event_freelancers
SET tech_types = ARRAY(
  SELECT x FROM unnest(tech_types) AS x
  WHERE x IN ('som', 'luz', 'video')
)
WHERE EXISTS (
  SELECT 1 FROM unnest(tech_types) AS x
  WHERE x IS NULL OR x NOT IN ('som', 'luz', 'video')
);

-- A view lista tech_type. CREATE OR REPLACE não remove coluna, então ela sai e volta.
DROP VIEW IF EXISTS event_crew_visible;

ALTER TABLE profiles DROP COLUMN IF EXISTS tech_type;
ALTER TABLE freelancers DROP COLUMN IF EXISTS tech_type;
ALTER TABLE event_freelancers DROP COLUMN IF EXISTS tech_type;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_tech_types_check;
ALTER TABLE profiles
  ADD CONSTRAINT profiles_tech_types_check
  CHECK (
    tech_types <@ ARRAY['som', 'luz', 'video']::text[]
    AND (
      (role = 'tecnico' AND cardinality(tech_types) >= 1)
      OR (role IS DISTINCT FROM 'tecnico' AND cardinality(tech_types) = 0)
    )
  );

ALTER TABLE event_freelancers DROP CONSTRAINT IF EXISTS event_freelancers_tech_types_check;
ALTER TABLE event_freelancers
  ADD CONSTRAINT event_freelancers_tech_types_check
  CHECK (tech_types <@ ARRAY['som', 'luz', 'video']::text[]);

CREATE VIEW event_crew_visible
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
  END AS daily_rate,
  tech_types
FROM event_freelancers;

GRANT SELECT ON event_crew_visible TO authenticated;

-- ---------------------------------------------------------------------------
-- Agenda individual do técnico
-- ---------------------------------------------------------------------------

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS agenda_all boolean;

UPDATE profiles p
SET agenda_all = COALESCE(
  (
    SELECT (c.flags->>'agenda_todos')::boolean
    FROM company_role_permissions c
    WHERE c.company_id = p.company_id
      AND c.role = 'tecnico'
  ),
  true
)
WHERE p.role = 'tecnico'
  AND p.agenda_all IS NULL;

UPDATE profiles
SET agenda_all = false
WHERE role IS DISTINCT FROM 'tecnico'
  AND agenda_all IS NULL;

ALTER TABLE profiles ALTER COLUMN agenda_all SET DEFAULT false;
ALTER TABLE profiles ALTER COLUMN agenda_all SET NOT NULL;

UPDATE company_role_permissions
SET flags = jsonb_set(COALESCE(flags, '{}'::jsonb), '{agenda_todos}', 'false'::jsonb, true)
WHERE role = 'tecnico';

CREATE OR REPLACE FUNCTION palco_default_grants(p_role text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_role
    WHEN 'admin' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":true,"estoque":true,"novo_item":true,"novo_freelancer":true,"novo_veiculo":true,"nova_manutencao":true,"novo_cliente":true,"novo_orcamento":true,"novo_lancamento":true,"freelancers":true,"veiculos":true,"clientes":true,"orcamentos":true,"financeiro":true,"equipe":true,"marca":true}'::jsonb
    WHEN 'gerente' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":true,"estoque":true,"novo_item":true,"novo_freelancer":true,"novo_veiculo":true,"nova_manutencao":true,"novo_cliente":true,"novo_orcamento":true,"novo_lancamento":true,"freelancers":true,"veiculos":true,"clientes":true,"orcamentos":true,"financeiro":true,"equipe":true,"marca":false}'::jsonb
    WHEN 'tecnico' THEN '{"inicio":true,"valores":false,"agenda":true,"agenda_todos":false,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":true,"veiculos":false,"clientes":false,"orcamentos":false,"financeiro":false,"equipe":false,"marca":false}'::jsonb
    WHEN 'financeiro' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":false,"orcamentos":true,"financeiro":true,"equipe":false,"marca":false}'::jsonb
    WHEN 'comercial' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":true,"orcamentos":true,"financeiro":false,"equipe":false,"marca":false}'::jsonb
    ELSE '{"inicio":false,"valores":false,"agenda":true,"agenda_todos":false,"novo_evento":false,"estoque":false,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":false,"orcamentos":false,"financeiro":false,"equipe":false,"marca":false}'::jsonb
  END;
$$;

-- Técnico: flag do próprio perfil. Freelancer: sempre falso.
-- Os outros cargos: caixa agenda_todos da matriz (ausente = ligada).
CREATE OR REPLACE FUNCTION agenda_sees_all()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN current_app_role() IS NULL OR current_app_role() = 'freelancer' THEN false
    WHEN current_app_role() = 'tecnico' THEN COALESCE(
      (
        SELECT p.agenda_all
        FROM profiles p
        WHERE p.auth_subject = current_jwt_sub()
      ),
      false
    )
    ELSE COALESCE(
      (
        SELECT (flags->>'agenda_todos')::boolean
        FROM company_role_permissions
        WHERE company_id = current_company_id()
          AND role = current_app_role()
      ),
      true
    )
  END;
$$;

REVOKE ALL ON FUNCTION agenda_sees_all() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION agenda_sees_all() TO authenticated;

-- Só o administrador muda tipo e agenda. O técnico não liga a própria flag.
CREATE OR REPLACE FUNCTION protect_profile()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  NEW.email := lower(btrim(NEW.email));
  NEW.full_name := btrim(NEW.full_name);
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;
  IF NEW.auth_subject IS DISTINCT FROM OLD.auth_subject
     OR NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Identidade do usuário não pode ser alterada';
  END IF;
  IF current_setting('app.allow_operator_profile_move', true) = 'on'
     OR current_setting('app.allow_operator_member_edit', true) = 'on' THEN
    RETURN NEW;
  END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id THEN
    RAISE EXCEPTION 'Identidade do usuário não pode ser alterada';
  END IF;
  IF OLD.role = 'admin' AND NEW.role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Só o operador remove um administrador';
  END IF;
  IF NEW.email IS DISTINCT FROM OLD.email
     AND current_app_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Apenas administradores alteram o e-mail do cadastro';
  END IF;
  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.active IS DISTINCT FROM OLD.active THEN
    IF current_app_role() IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'Apenas administradores alteram papel ou status';
    END IF;
    IF NEW.auth_subject = current_jwt_sub() AND NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Você não pode alterar o próprio papel';
    END IF;
  END IF;
  IF NEW.tech_types IS DISTINCT FROM OLD.tech_types
     OR NEW.agenda_all IS DISTINCT FROM OLD.agenda_all THEN
    IF current_app_role() IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'Apenas administradores alteram o tipo e a agenda do técnico';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Cadastro público não escolhe mais tipo. Técnico novo nasce na promoção do cargo.
DROP FUNCTION IF EXISTS join_company(text, text, text);
DROP FUNCTION IF EXISTS join_company(text, text, text, text);

CREATE FUNCTION join_company(
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
  v_email text := lower(btrim(COALESCE(p_email, '')));
  v_role text := 'freelancer';
  v_members integer;
  v_approved boolean;
  v_blocked boolean;
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
  SELECT id, approved, blocked INTO v_company, v_approved, v_blocked
  FROM companies
  WHERE invite_code = upper(btrim(COALESCE(p_code, '')));
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Código de convite inválido';
  END IF;
  IF v_blocked OR NOT v_approved THEN
    RAISE EXCEPTION 'Esta empresa ainda não foi autorizada';
  END IF;
  SELECT count(*) INTO v_members FROM profiles WHERE company_id = v_company;
  IF v_members = 0
     OR EXISTS (
       SELECT 1 FROM company_admin_reservations
       WHERE company_id = v_company AND email = v_email
     ) THEN
    v_role := 'admin';
  END IF;
  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), v_email, v_role);
  DELETE FROM company_admin_reservations
  WHERE company_id = v_company AND email = v_email;
  RETURN v_company;
END;
$$;

DROP FUNCTION IF EXISTS bootstrap_company(text, text, text, text, text);
DROP FUNCTION IF EXISTS bootstrap_company(text, text, text, text, text, text);

CREATE FUNCTION bootstrap_company(
  p_name text,
  p_full_name text,
  p_email text,
  p_primary text,
  p_secondary text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_company uuid;
  v_slug text;
  v_base text;
  v_code text;
  n integer := 0;
  tries integer := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE auth_subject = v_user) THEN
    RAISE EXCEPTION 'Usuário já vinculado a uma empresa';
  END IF;
  IF p_name IS NULL OR char_length(btrim(p_name)) < 2 THEN
    RAISE EXCEPTION 'Informe o nome da empresa';
  END IF;
  IF p_full_name IS NULL OR char_length(btrim(p_full_name)) < 2 THEN
    RAISE EXCEPTION 'Informe seu nome';
  END IF;
  IF p_primary !~ '^#[0-9A-Fa-f]{6}$' OR p_secondary !~ '^#[0-9A-Fa-f]{6}$' THEN
    RAISE EXCEPTION 'Cores inválidas';
  END IF;

  v_base := lower(btrim(p_name));
  v_base := translate(
    v_base,
    'áàâãäéèêëíìîïóòôõöúùûüçñ',
    'aaaaaeeeeiiiiooooouuuucn'
  );
  v_base := trim(BOTH '-' FROM regexp_replace(v_base, '[^a-z0-9]+', '-', 'g'));
  IF v_base IS NULL OR v_base = '' THEN
    v_base := 'empresa';
  END IF;
  v_slug := v_base;
  WHILE EXISTS (SELECT 1 FROM companies WHERE slug = v_slug) LOOP
    n := n + 1;
    v_slug := v_base || '-' || n::text;
  END LOOP;

  LOOP
    tries := tries + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM companies WHERE invite_code = v_code);
    IF tries > 5 THEN
      RAISE EXCEPTION 'Não foi possível gerar um código de convite';
    END IF;
  END LOOP;

  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  INSERT INTO companies (name, slug, primary_color, secondary_color, invite_code, approved, blocked)
  VALUES (btrim(p_name), v_slug, lower(p_primary), lower(p_secondary), v_code, false, false)
  RETURNING id INTO v_company;

  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'admin');

  PERFORM set_config('app.bypass_tenant', 'on', true);
  INSERT INTO equipment_categories (company_id, name) VALUES
    (v_company, 'Som'),
    (v_company, 'Iluminação'),
    (v_company, 'Vídeo'),
    (v_company, 'Estrutura'),
    (v_company, 'Outros');

  INSERT INTO finance_categories (company_id, name, kind) VALUES
    (v_company, 'Locação', 'receita'),
    (v_company, 'Serviço técnico', 'receita'),
    (v_company, 'Outros', 'receita'),
    (v_company, 'Transporte', 'despesa'),
    (v_company, 'Alimentação', 'despesa'),
    (v_company, 'Manutenção', 'despesa'),
    (v_company, 'Compras', 'despesa'),
    (v_company, 'Outros', 'despesa');

  RETURN v_company;
END;
$$;

REVOKE ALL ON FUNCTION join_company(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION bootstrap_company(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION join_company(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION bootstrap_company(text, text, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
