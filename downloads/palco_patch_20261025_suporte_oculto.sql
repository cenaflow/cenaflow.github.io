-- Cenaflow — login de suporte oculto na empresa (25/10/2026)
-- Cole só este arquivo no SQL Editor. Pode colar de novo. Não rode o SQL completo.
-- Não apaga tabela, não dá TRUNCATE e não dá DELETE.
--
-- profiles.is_support marca o login de suporte do dono do sistema.
-- Quem não é suporte não lê essa linha (RLS), então ela some da Equipe,
-- das listas de técnicos e de qualquer tela que leia profiles.
-- O próprio suporte continua lendo a si mesmo e a empresa toda, com o papel que tiver.
-- Só o SQL Editor (sem sessão de usuário) liga ou desliga a marca.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_support boolean;
UPDATE profiles SET is_support = false WHERE is_support IS NULL;
ALTER TABLE profiles ALTER COLUMN is_support SET DEFAULT false;
ALTER TABLE profiles ALTER COLUMN is_support SET NOT NULL;

-- A sessão atual é de um login de suporte?
CREATE OR REPLACE FUNCTION current_is_support()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT p.is_support FROM profiles p WHERE p.auth_subject = current_jwt_sub() LIMIT 1),
    false
  );
$$;

REVOKE ALL ON FUNCTION current_is_support() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_is_support() TO authenticated;

DROP POLICY IF EXISTS profiles_select ON profiles;
CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (
    auth_subject = current_jwt_sub()
    OR (
      company_id = current_company_id()
      AND current_app_role() IS DISTINCT FROM 'freelancer'
      AND (NOT is_support OR current_is_support())
    )
  );

-- Pelo app ninguém liga/desliga a marca de suporte (nem o admin da empresa).
CREATE OR REPLACE FUNCTION protect_support_flag()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_jwt_sub() IS NOT NULL THEN
    IF TG_OP = 'INSERT' THEN
      NEW.is_support := false;
    ELSIF NEW.is_support IS DISTINCT FROM OLD.is_support THEN
      RAISE EXCEPTION 'A marca de suporte só muda pelo SQL Editor';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION protect_support_flag() TO authenticated;

DROP TRIGGER IF EXISTS trg_01_protect_support ON profiles;
CREATE TRIGGER trg_01_protect_support
  BEFORE INSERT OR UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION protect_support_flag();

-- Marca o login de suporte em todas as empresas. Rode de novo depois de entrar
-- numa empresa nova com esse login.
UPDATE profiles
SET is_support = true
WHERE lower(btrim(email)) = 'matheus.work.cremonese@gmail.com'
  AND is_support IS DISTINCT FROM true;

NOTIFY pgrst, 'reload schema';
