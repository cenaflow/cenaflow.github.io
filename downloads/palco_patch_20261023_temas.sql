-- Palco — temas, acessos por cargo e fim do papel estoque (23/10/2026)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez.
-- Não apaga tabela, não dá TRUNCATE e não dá DELETE sem filtro.
-- Há dois DELETE filtrados, só em role_price_visibility:
--   WHERE role = 'visualizador' e WHERE role = 'estoque',
-- depois de copiar a linha quando não há conflito com freelancer ou técnico.
-- Nenhum evento, orçamento ou item é apagado.
-- Quem era estoque passa a técnico. Quem ainda era visualizador passa a freelancer.

SELECT set_config('app.bypass_tenant', 'on', false);

-- ---------------------------------------------------------------------------
-- Cargo estoque vira técnico
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
      AND pg_get_constraintdef(con.oid) ILIKE '%estoque%'
  LOOP
    EXECUTE format('ALTER TABLE profiles DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

UPDATE profiles SET role = 'freelancer' WHERE role = 'visualizador';
UPDATE profiles SET role = 'tecnico' WHERE role = 'estoque';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_role_check'
  ) THEN
    ALTER TABLE profiles
      ADD CONSTRAINT profiles_role_check
      CHECK (role IN ('admin', 'gerente', 'financeiro', 'tecnico', 'comercial', 'freelancer'));
  END IF;
END $$;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'role_price_visibility'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%estoque%'
  LOOP
    EXECUTE format('ALTER TABLE role_price_visibility DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

UPDATE role_price_visibility
SET role = 'freelancer'
WHERE role = 'visualizador'
  AND NOT EXISTS (
    SELECT 1 FROM role_price_visibility other
    WHERE other.company_id = role_price_visibility.company_id
      AND other.role = 'freelancer'
  );
DELETE FROM role_price_visibility WHERE role = 'visualizador';

UPDATE role_price_visibility
SET role = 'tecnico'
WHERE role = 'estoque'
  AND NOT EXISTS (
    SELECT 1 FROM role_price_visibility other
    WHERE other.company_id = role_price_visibility.company_id
      AND other.role = 'tecnico'
  );

DELETE FROM role_price_visibility WHERE role = 'estoque';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'role_price_visibility_role_check'
  ) THEN
    ALTER TABLE role_price_visibility
      ADD CONSTRAINT role_price_visibility_role_check
      CHECK (role IN ('admin', 'gerente', 'financeiro', 'tecnico', 'comercial', 'freelancer'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Tema da empresa
-- ---------------------------------------------------------------------------

ALTER TABLE companies ADD COLUMN IF NOT EXISTS theme_id text NOT NULL DEFAULT 'noite';
ALTER TABLE companies ADD COLUMN IF NOT EXISTS sidebar_color text NOT NULL DEFAULT '#10201f';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'companies_theme_id_check') THEN
    ALTER TABLE companies
      ADD CONSTRAINT companies_theme_id_check
      CHECK (theme_id ~ '^[a-z0-9_]{2,32}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'companies_sidebar_color_check') THEN
    ALTER TABLE companies
      ADD CONSTRAINT companies_sidebar_color_check
      CHECK (sidebar_color ~ '^#[0-9a-f]{6}$');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Acessos por cargo
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION palco_default_grants(p_role text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_role
    WHEN 'admin' THEN '{"inicio":true,"valores":true,"agenda":true,"novo_evento":true,"estoque":true,"novo_item":true,"novo_freelancer":true,"novo_veiculo":true,"nova_manutencao":true,"novo_cliente":true,"novo_orcamento":true,"novo_lancamento":true,"freelancers":true,"veiculos":true,"clientes":true,"orcamentos":true,"financeiro":true,"equipe":true,"marca":true}'::jsonb
    WHEN 'gerente' THEN '{"inicio":true,"valores":true,"agenda":true,"novo_evento":true,"estoque":true,"novo_item":true,"novo_freelancer":true,"novo_veiculo":true,"nova_manutencao":true,"novo_cliente":true,"novo_orcamento":true,"novo_lancamento":true,"freelancers":true,"veiculos":true,"clientes":true,"orcamentos":true,"financeiro":true,"equipe":true,"marca":false}'::jsonb
    WHEN 'tecnico' THEN '{"inicio":true,"valores":false,"agenda":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":true,"veiculos":false,"clientes":false,"orcamentos":false,"financeiro":false,"equipe":false,"marca":false}'::jsonb
    WHEN 'financeiro' THEN '{"inicio":true,"valores":true,"agenda":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":false,"orcamentos":true,"financeiro":true,"equipe":false,"marca":false}'::jsonb
    WHEN 'comercial' THEN '{"inicio":true,"valores":true,"agenda":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":true,"orcamentos":true,"financeiro":false,"equipe":false,"marca":false}'::jsonb
    ELSE '{"inicio":false,"valores":false,"agenda":true,"novo_evento":false,"estoque":false,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":false,"orcamentos":false,"financeiro":false,"equipe":false,"marca":false}'::jsonb
  END;
$$;

CREATE TABLE IF NOT EXISTS company_role_permissions (
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  role text NOT NULL,
  flags jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (company_id, role)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'company_role_permissions_role_check'
  ) THEN
    ALTER TABLE company_role_permissions
      ADD CONSTRAINT company_role_permissions_role_check
      CHECK (role IN ('admin', 'gerente', 'financeiro', 'tecnico', 'comercial', 'freelancer'));
  END IF;
END $$;

INSERT INTO company_role_permissions (company_id, role, flags)
SELECT c.id,
       r.role,
       CASE
         WHEN r.role = 'freelancer' THEN palco_default_grants(r.role)
         ELSE jsonb_set(
           palco_default_grants(r.role),
           '{valores}',
           to_jsonb(COALESCE(v.can_see_prices, (palco_default_grants(r.role)->>'valores')::boolean))
         )
       END
FROM companies c
CROSS JOIN (
  VALUES ('admin'), ('gerente'), ('financeiro'), ('tecnico'), ('comercial'), ('freelancer')
) AS r(role)
LEFT JOIN role_price_visibility v
  ON v.company_id = c.id AND v.role = r.role
ON CONFLICT (company_id, role) DO NOTHING;

CREATE OR REPLACE FUNCTION seed_company_access()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('app.bypass_tenant', 'on', true);
  INSERT INTO company_role_permissions (company_id, role, flags)
  SELECT NEW.id, r.role, palco_default_grants(r.role)
  FROM (
    VALUES ('admin'), ('gerente'), ('financeiro'), ('tecnico'), ('comercial'), ('freelancer')
  ) AS r(role)
  ON CONFLICT (company_id, role) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_company_access ON companies;
CREATE TRIGGER trg_seed_company_access
  AFTER INSERT ON companies
  FOR EACH ROW EXECUTE FUNCTION seed_company_access();

DROP TRIGGER IF EXISTS trg_00_tenant ON company_role_permissions;
CREATE TRIGGER trg_00_tenant
  BEFORE INSERT OR UPDATE ON company_role_permissions
  FOR EACH ROW EXECUTE FUNCTION set_tenant_company();

ALTER TABLE company_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE company_role_permissions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS company_role_permissions_select ON company_role_permissions;
CREATE POLICY company_role_permissions_select ON company_role_permissions
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND current_app_role() IS DISTINCT FROM 'freelancer'
  );

DROP POLICY IF EXISTS company_role_permissions_write ON company_role_permissions;
CREATE POLICY company_role_permissions_write ON company_role_permissions
  FOR ALL TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() = 'admin'
      OR (current_app_role() = 'gerente' AND role <> 'admin' AND role <> 'freelancer')
    )
  )
  WITH CHECK (
    company_id = current_company_id()
    AND (
      current_app_role() = 'admin'
      OR (current_app_role() = 'gerente' AND role <> 'admin' AND role <> 'freelancer')
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON company_role_permissions TO authenticated;
GRANT EXECUTE ON FUNCTION palco_default_grants(text) TO authenticated;
GRANT EXECUTE ON FUNCTION seed_company_access() TO authenticated;
