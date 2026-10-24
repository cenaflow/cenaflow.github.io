-- Palco — painel do operador da plataforma.
-- Idempotente. Não apaga tabela, não dá TRUNCATE e não dá DELETE sem filtro.
-- O e-mail do operador fica em platform_operators. As funções recusam
-- quem não está nessa tabela, mesmo que o aplicativo tente chamar.

ALTER TABLE companies ADD COLUMN IF NOT EXISTS blocked boolean NOT NULL DEFAULT false;

-- Empresa nova nasce pendente. Quem já existia continua autorizada.
ALTER TABLE companies ADD COLUMN IF NOT EXISTS approved boolean;
UPDATE companies SET approved = true WHERE approved IS NULL;
ALTER TABLE companies ALTER COLUMN approved SET DEFAULT false;
ALTER TABLE companies ALTER COLUMN approved SET NOT NULL;

CREATE TABLE IF NOT EXISTS platform_operators (
  email text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO platform_operators (email)
VALUES ('matheus.work.cremonese@gmail.com')
ON CONFLICT (email) DO NOTHING;

CREATE TABLE IF NOT EXISTS company_admin_reservations (
  company_id uuid PRIMARY KEY REFERENCES companies (id) ON DELETE CASCADE,
  email text NOT NULL,
  full_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS company_admin_reservations_email_uq
  ON company_admin_reservations (email);

ALTER TABLE company_admin_reservations ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid();
UPDATE company_admin_reservations SET id = gen_random_uuid() WHERE id IS NULL;

DO $$
DECLARE
  v_cols text;
BEGIN
  SELECT string_agg(a.attname, ',' ORDER BY k.ord)
  INTO v_cols
  FROM pg_constraint c
  JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
  WHERE c.conrelid = 'company_admin_reservations'::regclass
    AND c.contype = 'p';
  IF v_cols = 'company_id' THEN
    ALTER TABLE company_admin_reservations DROP CONSTRAINT company_admin_reservations_pkey;
    ALTER TABLE company_admin_reservations ALTER COLUMN id SET NOT NULL;
    ALTER TABLE company_admin_reservations ADD PRIMARY KEY (id);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS company_admin_reservations_company_email_uq
  ON company_admin_reservations (company_id, email);

ALTER TABLE platform_operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_operators FORCE ROW LEVEL SECURITY;
ALTER TABLE company_admin_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE company_admin_reservations FORCE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION current_jwt_email()
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  claims text;
BEGIN
  claims := NULLIF(current_setting('request.jwt.claims', true), '');
  IF claims IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN NULLIF(lower(btrim(claims::json->>'email')), '');
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION is_platform_operator()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM platform_operators
    WHERE email = current_jwt_email()
  );
$$;

CREATE OR REPLACE FUNCTION current_company_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN (
    SELECT p.company_id
    FROM profiles p
    JOIN companies c ON c.id = p.company_id
    WHERE p.auth_subject = current_jwt_sub()
      AND p.active
      AND c.approved
      AND NOT c.blocked
    LIMIT 1
  );
END;
$$;

CREATE OR REPLACE FUNCTION current_app_role()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN (
    SELECT p.role
    FROM profiles p
    JOIN companies c ON c.id = p.company_id
    WHERE p.auth_subject = current_jwt_sub()
      AND p.active
      AND c.approved
      AND NOT c.blocked
    LIMIT 1
  );
END;
$$;

CREATE OR REPLACE FUNCTION company_login_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approved boolean;
  v_blocked boolean;
BEGIN
  SELECT c.approved, c.blocked INTO v_approved, v_blocked
  FROM profiles p
  JOIN companies c ON c.id = p.company_id
  WHERE p.auth_subject = current_jwt_sub()
    AND p.active
  LIMIT 1;
  IF v_approved IS NULL THEN
    RETURN true;
  END IF;
  RETURN v_approved AND NOT v_blocked;
END;
$$;

CREATE OR REPLACE FUNCTION assert_platform_operator()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF NOT is_platform_operator() THEN
    RAISE EXCEPTION 'Sem acesso de operador';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION operator_list_companies()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_platform_operator();
  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC)
    FROM (
      SELECT c.id,
             c.name,
             c.slug,
             c.blocked, c.approved,
             c.invite_code,
             c.storage_used_bytes,
             c.storage_quota_bytes,
             c.created_at,
             (SELECT count(*) FROM profiles p WHERE p.company_id = c.id) AS members
      FROM companies c
    ) row
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION operator_company_members(p_company uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_platform_operator();
  IF NOT EXISTS (SELECT 1 FROM companies WHERE id = p_company) THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(row) ORDER BY row.full_name)
    FROM (
      SELECT p.id, p.full_name, p.email, p.role, p.active
      FROM profiles p
      WHERE p.company_id = p_company
    ) row
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION operator_create_company(
  p_name text,
  p_slug text,
  p_invite_code text,
  p_admin_email text,
  p_admin_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_name text := btrim(COALESCE(p_name, ''));
  v_slug text := lower(btrim(COALESCE(p_slug, '')));
  v_code text := upper(btrim(COALESCE(p_invite_code, '')));
  v_email text := lower(btrim(COALESCE(p_admin_email, '')));
  v_admin text := btrim(COALESCE(p_admin_name, ''));
  v_id uuid;
  tries integer := 0;
BEGIN
  PERFORM assert_platform_operator();
  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'Informe o nome da empresa';
  END IF;
  IF v_slug = '' THEN
    v_slug := trim(BOTH '-' FROM regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'));
    v_slug := lower(v_slug);
  END IF;
  IF v_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' THEN
    RAISE EXCEPTION 'O slug só pode ter letras minúsculas, números e hífen';
  END IF;
  IF EXISTS (SELECT 1 FROM companies WHERE slug = v_slug) THEN
    RAISE EXCEPTION 'Já existe empresa com esse slug';
  END IF;
  IF v_code = '' THEN
    LOOP
      tries := tries + 1;
      v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
      EXIT WHEN NOT EXISTS (SELECT 1 FROM companies WHERE invite_code = v_code);
      IF tries > 5 THEN
        RAISE EXCEPTION 'Não foi possível gerar um código de convite';
      END IF;
    END LOOP;
  ELSIF v_code !~ '^[A-Z0-9]{6,16}$' THEN
    RAISE EXCEPTION 'O código de convite precisa ter 6 a 16 letras ou números';
  ELSIF EXISTS (SELECT 1 FROM companies WHERE invite_code = v_code) THEN
    RAISE EXCEPTION 'Esse código de convite já existe';
  END IF;
  IF v_email <> '' AND (position('@' in v_email) = 0 OR char_length(v_admin) < 2) THEN
    RAISE EXCEPTION 'Informe o e-mail e o nome do administrador inicial';
  END IF;

  INSERT INTO companies (name, slug, invite_code, approved)
  VALUES (v_name, v_slug, v_code, false)
  RETURNING id INTO v_id;

  IF v_email <> '' THEN
    INSERT INTO company_admin_reservations (company_id, email, full_name)
    VALUES (v_id, v_email, v_admin);
  END IF;

  RETURN (
    SELECT to_jsonb(row)
    FROM (
      SELECT c.id, c.name, c.slug, c.blocked, c.approved, c.invite_code,
             c.storage_used_bytes, c.storage_quota_bytes, c.created_at,
             0 AS members
      FROM companies c
      WHERE c.id = v_id
    ) row
  );
END;
$$;

CREATE OR REPLACE FUNCTION operator_update_company(
  p_company uuid,
  p_name text,
  p_slug text,
  p_quota_bytes bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text := btrim(COALESCE(p_name, ''));
  v_slug text := lower(btrim(COALESCE(p_slug, '')));
BEGIN
  PERFORM assert_platform_operator();
  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'Informe o nome da empresa';
  END IF;
  IF v_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' THEN
    RAISE EXCEPTION 'O slug só pode ter letras minúsculas, números e hífen';
  END IF;
  IF EXISTS (SELECT 1 FROM companies WHERE slug = v_slug AND id <> p_company) THEN
    RAISE EXCEPTION 'Já existe empresa com esse slug';
  END IF;
  IF p_quota_bytes IS NULL OR p_quota_bytes < 0 THEN
    RAISE EXCEPTION 'A cota de armazenamento é inválida';
  END IF;
  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  UPDATE companies
  SET name = v_name,
      slug = v_slug,
      storage_quota_bytes = p_quota_bytes
  WHERE id = p_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
  RETURN (
    SELECT to_jsonb(row)
    FROM (
      SELECT c.id, c.name, c.slug, c.blocked, c.approved, c.invite_code,
             c.storage_used_bytes, c.storage_quota_bytes, c.created_at,
             (SELECT count(*) FROM profiles p WHERE p.company_id = c.id) AS members
      FROM companies c
      WHERE c.id = p_company
    ) row
  );
END;
$$;

CREATE OR REPLACE FUNCTION operator_set_company_blocked(p_company uuid, p_blocked boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_platform_operator();
  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  UPDATE companies SET blocked = COALESCE(p_blocked, false) WHERE id = p_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION operator_regenerate_invite(p_company uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_code text;
  tries integer := 0;
BEGIN
  PERFORM assert_platform_operator();
  IF NOT EXISTS (SELECT 1 FROM companies WHERE id = p_company) THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
  LOOP
    tries := tries + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM companies WHERE invite_code = v_code);
    IF tries > 5 THEN
      RAISE EXCEPTION 'Não foi possível gerar um código';
    END IF;
  END LOOP;
  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  UPDATE companies SET invite_code = v_code WHERE id = p_company;
  RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION claim_reserved_admin()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_email text := current_jwt_email();
  v_row company_admin_reservations%ROWTYPE;
BEGIN
  IF v_user IS NULL OR v_email IS NULL THEN
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE auth_subject = v_user) THEN
    RETURN false;
  END IF;
  SELECT * INTO v_row
  FROM company_admin_reservations
  WHERE email = v_email
  ORDER BY created_at
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_row.company_id, v_row.full_name, v_row.email, 'admin');
  DELETE FROM company_admin_reservations
  WHERE company_id = v_row.company_id
    AND email = v_row.email;
  RETURN true;
END;
$$;

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

GRANT EXECUTE ON FUNCTION current_jwt_email() TO authenticated;
GRANT EXECUTE ON FUNCTION is_platform_operator() TO authenticated;
GRANT EXECUTE ON FUNCTION company_login_open() TO authenticated;
GRANT EXECUTE ON FUNCTION operator_list_companies() TO authenticated;
GRANT EXECUTE ON FUNCTION operator_company_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_create_company(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_update_company(uuid, text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_set_company_blocked(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_regenerate_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION claim_reserved_admin() TO authenticated;

REVOKE ALL ON FUNCTION current_jwt_email() FROM PUBLIC;
REVOKE ALL ON FUNCTION is_platform_operator() FROM PUBLIC;
REVOKE ALL ON FUNCTION company_login_open() FROM PUBLIC;
REVOKE ALL ON FUNCTION assert_platform_operator() FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_list_companies() FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_company_members(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_create_company(text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_update_company(uuid, text, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_set_company_blocked(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_regenerate_invite(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION claim_reserved_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_jwt_email() TO authenticated;
GRANT EXECUTE ON FUNCTION is_platform_operator() TO authenticated;
GRANT EXECUTE ON FUNCTION company_login_open() TO authenticated;
GRANT EXECUTE ON FUNCTION operator_list_companies() TO authenticated;
GRANT EXECUTE ON FUNCTION operator_company_members(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_create_company(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_update_company(uuid, text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_set_company_blocked(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_regenerate_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION claim_reserved_admin() TO authenticated;

-- O gatilho antigo ainda gravava os cargos estoque e visualizador.
-- Depois do patch de temas esses cargos não existem mais, e criar empresa falhava.
CREATE OR REPLACE FUNCTION seed_price_visibility()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  PERFORM set_config('app.bypass_tenant', 'on', true);
  INSERT INTO role_price_visibility (company_id, role, can_see_prices)
  SELECT NEW.id, r.role, r.can_see
  FROM (VALUES
    ('admin', true),
    ('gerente', true),
    ('financeiro', true),
    ('comercial', true),
    ('tecnico', false),
    ('freelancer', false)
  ) AS r(role, can_see)
  ON CONFLICT (company_id, role) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Estado visto pelo login: none, open, pending ou blocked.
CREATE OR REPLACE FUNCTION company_access_state()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_approved boolean;
  v_blocked boolean;
BEGIN
  SELECT c.approved, c.blocked INTO v_approved, v_blocked
  FROM profiles p
  JOIN companies c ON c.id = p.company_id
  WHERE p.auth_subject = current_jwt_sub()
  LIMIT 1;
  IF v_approved IS NULL THEN
    RETURN 'none';
  END IF;
  IF v_blocked THEN
    RETURN 'blocked';
  END IF;
  IF NOT v_approved THEN
    RETURN 'pending';
  END IF;
  RETURN 'open';
END;
$$;

-- Nome, slug, cota, convite, aprovação e bloqueio não saem pelo UPDATE comum.
CREATE OR REPLACE FUNCTION protect_company_storage()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  IF NEW.storage_used_bytes IS DISTINCT FROM OLD.storage_used_bytes
     OR NEW.storage_quota_bytes IS DISTINCT FROM OLD.storage_quota_bytes
     OR NEW.invite_code IS DISTINCT FROM OLD.invite_code
     OR NEW.slug IS DISTINCT FROM OLD.slug
     OR NEW.id IS DISTINCT FROM OLD.id
     OR NEW.approved IS DISTINCT FROM OLD.approved
     OR NEW.blocked IS DISTINCT FROM OLD.blocked THEN
    IF current_setting('app.allow_internal_company_update', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'Campos internos da empresa só mudam por funções do sistema';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- O operador move o próprio perfil ou edita um administrador.
-- A empresa não rebaixa um administrador: isso fica no painel.
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
  RETURN NEW;
END;
$$;

-- Cadastro público cria o pedido pendente e não libera o aplicativo.
CREATE OR REPLACE FUNCTION bootstrap_company(
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

CREATE OR REPLACE FUNCTION operator_authorize_company(p_company uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_platform_operator();
  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  UPDATE companies
  SET approved = true,
      blocked = false
  WHERE id = p_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
END;
$$;

-- O operador passa a ser membro só desta empresa. Nada é copiado de outra.
CREATE OR REPLACE FUNCTION operator_enter_company(p_company uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_email text := current_jwt_email();
  v_approved boolean;
  v_blocked boolean;
  v_name text;
BEGIN
  PERFORM assert_platform_operator();
  IF v_user IS NULL OR v_email IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida';
  END IF;
  SELECT approved, blocked INTO v_approved, v_blocked
  FROM companies
  WHERE id = p_company;
  IF v_approved IS NULL THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
  IF NOT v_approved OR v_blocked THEN
    RAISE EXCEPTION 'Autorize a empresa antes de entrar';
  END IF;
  IF EXISTS (
    SELECT 1 FROM profiles
    WHERE company_id = p_company
      AND email = v_email
      AND auth_subject IS DISTINCT FROM v_user
  ) THEN
    RAISE EXCEPTION 'Já existe um membro com este e-mail nesta empresa';
  END IF;

  SELECT full_name INTO v_name
  FROM profiles
  WHERE auth_subject = v_user;

  IF v_name IS NULL OR btrim(v_name) = '' THEN
    v_name := 'Operador';
  END IF;

  IF EXISTS (SELECT 1 FROM profiles WHERE auth_subject = v_user) THEN
    PERFORM set_config('app.allow_operator_profile_move', 'on', true);
    UPDATE profiles
    SET company_id = p_company,
        role = 'admin',
        active = true,
        email = v_email,
        full_name = v_name
    WHERE auth_subject = v_user;
  ELSE
    INSERT INTO profiles (auth_subject, company_id, full_name, email, role, active)
    VALUES (v_user, p_company, v_name, v_email, 'admin', true);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION operator_list_admins(p_company uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_platform_operator();
  IF NOT EXISTS (SELECT 1 FROM companies WHERE id = p_company) THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(row) ORDER BY row.link, row.full_name)
    FROM (
      SELECT p.id::text AS id,
             p.full_name,
             p.email,
             'membro' AS link
      FROM profiles p
      WHERE p.company_id = p_company
        AND p.role = 'admin'
      UNION ALL
      SELECT NULL::text,
             r.full_name,
             r.email,
             'reserva'
      FROM company_admin_reservations r
      WHERE r.company_id = p_company
    ) row
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION operator_save_admin(
  p_company uuid,
  p_profile uuid,
  p_email text,
  p_name text,
  p_previous_email text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(btrim(COALESCE(p_email, '')));
  v_name text := btrim(COALESCE(p_name, ''));
  v_previous text := lower(btrim(COALESCE(p_previous_email, '')));
  v_existing uuid;
BEGIN
  PERFORM assert_platform_operator();
  IF NOT EXISTS (SELECT 1 FROM companies WHERE id = p_company) THEN
    RAISE EXCEPTION 'Empresa não encontrada';
  END IF;
  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'Informe o nome do administrador';
  END IF;
  IF position('@' in v_email) = 0 OR position('.' in v_email) = 0 THEN
    RAISE EXCEPTION 'Informe um e-mail válido';
  END IF;
  IF EXISTS (
    SELECT 1 FROM profiles
    WHERE email = v_email
      AND company_id <> p_company
      AND (p_profile IS NULL OR id <> p_profile)
  ) THEN
    RAISE EXCEPTION 'Este e-mail já está em outra empresa';
  END IF;
  IF EXISTS (
    SELECT 1 FROM company_admin_reservations
    WHERE email = v_email
      AND company_id <> p_company
  ) THEN
    RAISE EXCEPTION 'Este e-mail já está reservado em outra empresa';
  END IF;

  IF p_profile IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM profiles WHERE id = p_profile AND company_id = p_company
    ) THEN
      RAISE EXCEPTION 'Administrador de outra empresa';
    END IF;
    IF EXISTS (
      SELECT 1 FROM profiles
      WHERE company_id = p_company
        AND email = v_email
        AND id <> p_profile
    ) THEN
      RAISE EXCEPTION 'Já existe um membro com este e-mail nesta empresa';
    END IF;
    PERFORM set_config('app.allow_operator_member_edit', 'on', true);
    UPDATE profiles
    SET full_name = v_name,
        email = v_email,
        role = 'admin',
        active = true
    WHERE id = p_profile
      AND company_id = p_company;
    DELETE FROM company_admin_reservations
    WHERE company_id = p_company
      AND email = v_email;
    RETURN;
  END IF;

  SELECT id INTO v_existing
  FROM profiles
  WHERE company_id = p_company
    AND email = v_email
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    PERFORM set_config('app.allow_operator_member_edit', 'on', true);
    UPDATE profiles
    SET full_name = v_name,
        role = 'admin',
        active = true
    WHERE id = v_existing
      AND company_id = p_company;
    DELETE FROM company_admin_reservations
    WHERE company_id = p_company
      AND email IN (v_email, v_previous);
    RETURN;
  END IF;

  IF v_previous <> '' AND v_previous <> v_email THEN
    DELETE FROM company_admin_reservations
    WHERE company_id = p_company
      AND email = v_previous;
  END IF;

  INSERT INTO company_admin_reservations (company_id, email, full_name)
  VALUES (p_company, v_email, v_name)
  ON CONFLICT (email) DO UPDATE
  SET full_name = EXCLUDED.full_name,
      company_id = EXCLUDED.company_id
  WHERE company_admin_reservations.company_id = EXCLUDED.company_id;
END;
$$;

CREATE OR REPLACE FUNCTION operator_remove_member(p_company uuid, p_profile uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subject text;
BEGIN
  PERFORM assert_platform_operator();
  SELECT auth_subject INTO v_subject
  FROM profiles
  WHERE id = p_profile
    AND company_id = p_company;
  IF v_subject IS NULL AND NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = p_profile AND company_id = p_company
  ) THEN
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_profile) THEN
      RAISE EXCEPTION 'Membro não encontrado';
    END IF;
    RAISE EXCEPTION 'Conta de outra empresa';
  END IF;

  UPDATE freelancer_invites
  SET status = 'revoked', updated_at = now()
  WHERE company_id = p_company
    AND auth_subject = v_subject
    AND status <> 'revoked';

  DELETE FROM profiles
  WHERE id = p_profile
    AND company_id = p_company;
END;
$$;

CREATE OR REPLACE FUNCTION operator_remove_admin_reservation(p_company uuid, p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(btrim(COALESCE(p_email, '')));
BEGIN
  PERFORM assert_platform_operator();
  DELETE FROM company_admin_reservations
  WHERE company_id = p_company
    AND email = v_email;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva não encontrada';
  END IF;
END;
$$;

-- Administrador da empresa não apaga administrador nem esvazia a empresa.
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
  v_members integer;
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
    RAISE EXCEPTION 'Só o operador remove um administrador';
  END IF;

  SELECT count(*) INTO v_members
  FROM profiles
  WHERE company_id = v_company;
  IF v_members <= 1 THEN
    RAISE EXCEPTION 'Só o operador pode deixar a empresa sem usuários';
  END IF;

  UPDATE freelancer_invites
  SET status = 'revoked', updated_at = now()
  WHERE company_id = v_company
    AND auth_subject = v_target_subject
    AND status <> 'revoked';

  DELETE FROM profiles WHERE id = p_profile_id AND company_id = v_company;
END;
$$;

-- Isolamento: estas tabelas não têm policy para o papel authenticated.
REVOKE ALL ON TABLE platform_operators FROM PUBLIC;
REVOKE ALL ON TABLE company_admin_reservations FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON TABLE platform_operators FROM anon';
    EXECUTE 'REVOKE ALL ON TABLE company_admin_reservations FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON TABLE platform_operators FROM authenticated';
    EXECUTE 'REVOKE ALL ON TABLE company_admin_reservations FROM authenticated';
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION company_access_state() TO authenticated;
GRANT EXECUTE ON FUNCTION operator_authorize_company(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_enter_company(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_list_admins(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_save_admin(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_remove_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_remove_admin_reservation(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION company_access_state() FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_authorize_company(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_enter_company(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_list_admins(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_save_admin(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_remove_member(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION operator_remove_admin_reservation(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION company_access_state() TO authenticated;
GRANT EXECUTE ON FUNCTION operator_authorize_company(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_enter_company(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_list_admins(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_save_admin(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_remove_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION operator_remove_admin_reservation(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
