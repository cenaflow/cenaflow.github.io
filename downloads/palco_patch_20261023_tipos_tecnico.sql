-- Palco — patch de tipo de técnico (23/10/2026)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez. Não apaga tabela, não trunca e não dá DELETE.
--
-- Cada perfil e cada freelancer ganha tech_type: som, luz ou video.
-- Quem já existia fica som. O evento guarda uma cópia do tipo na hora da seleção.
-- A agenda (todos os eventos / só selecionados) não muda.

SELECT set_config('app.bypass_tenant', 'on', false);

-- ---------------------------------------------------------------------------
-- Colunas
-- ---------------------------------------------------------------------------

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS tech_type text;
UPDATE profiles
SET tech_type = 'som'
WHERE tech_type IS NULL
   OR btrim(tech_type) = ''
   OR tech_type NOT IN ('som', 'luz', 'video');
ALTER TABLE profiles ALTER COLUMN tech_type SET DEFAULT 'som';
ALTER TABLE profiles ALTER COLUMN tech_type SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_tech_type_check'
  ) THEN
    ALTER TABLE profiles
      ADD CONSTRAINT profiles_tech_type_check
      CHECK (tech_type IN ('som', 'luz', 'video'));
  END IF;
END $$;

ALTER TABLE freelancers ADD COLUMN IF NOT EXISTS tech_type text;
UPDATE freelancers
SET tech_type = 'som'
WHERE tech_type IS NULL
   OR btrim(tech_type) = ''
   OR tech_type NOT IN ('som', 'luz', 'video');
ALTER TABLE freelancers ALTER COLUMN tech_type SET DEFAULT 'som';
ALTER TABLE freelancers ALTER COLUMN tech_type SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'freelancers_tech_type_check'
  ) THEN
    ALTER TABLE freelancers
      ADD CONSTRAINT freelancers_tech_type_check
      CHECK (tech_type IN ('som', 'luz', 'video'));
  END IF;
END $$;

ALTER TABLE event_freelancers ADD COLUMN IF NOT EXISTS tech_type text;
UPDATE event_freelancers
SET tech_type = 'som'
WHERE tech_type IS NULL
   OR btrim(tech_type) = ''
   OR tech_type NOT IN ('som', 'luz', 'video');
ALTER TABLE event_freelancers ALTER COLUMN tech_type SET DEFAULT 'som';
ALTER TABLE event_freelancers ALTER COLUMN tech_type SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'event_freelancers_tech_type_check'
  ) THEN
    ALTER TABLE event_freelancers
      ADD CONSTRAINT event_freelancers_tech_type_check
      CHECK (tech_type IN ('som', 'luz', 'video'));
  END IF;
END $$;

-- A view lista colunas. Sem este replace o app não lê o tipo.
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
  END AS daily_rate,
  tech_type
FROM event_freelancers;

-- ---------------------------------------------------------------------------
-- Cadastro: o tipo escolhido na hora entra no perfil.
-- A assinatura antiga sai para o PostgREST não ficar com duas funções.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS join_company(text, text, text);
DROP FUNCTION IF EXISTS join_company(text, text, text, text);

CREATE FUNCTION join_company(
  p_code text,
  p_full_name text,
  p_email text,
  p_tech_type text DEFAULT 'som'
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
  v_type text := lower(btrim(COALESCE(p_tech_type, '')));
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
  IF v_type IN ('', 'som') THEN
    v_type := 'som';
  ELSIF v_type = 'luz' THEN
    v_type := 'luz';
  ELSIF v_type IN ('video', 'vídeo') THEN
    v_type := 'video';
  ELSE
    RAISE EXCEPTION 'Tipo inválido. Use som, luz ou video.';
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
  INSERT INTO profiles (auth_subject, company_id, full_name, email, role, tech_type)
  VALUES (v_user, v_company, btrim(p_full_name), v_email, v_role, v_type);
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
  p_secondary text,
  p_tech_type text DEFAULT 'som'
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
  v_type text := lower(btrim(COALESCE(p_tech_type, '')));
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
  IF v_type IN ('', 'som') THEN
    v_type := 'som';
  ELSIF v_type = 'luz' THEN
    v_type := 'luz';
  ELSIF v_type IN ('video', 'vídeo') THEN
    v_type := 'video';
  ELSE
    RAISE EXCEPTION 'Tipo inválido. Use som, luz ou video.';
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

  INSERT INTO profiles (auth_subject, company_id, full_name, email, role, tech_type)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'admin', v_type);

  -- A empresa ainda está pendente, então current_company_id é nulo.
  -- O gatilho de tenant só aceita o id explícito com este bypass.
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

REVOKE ALL ON FUNCTION join_company(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION bootstrap_company(text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION join_company(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION bootstrap_company(text, text, text, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
