-- Palco — patch: as flags internas (app.bypass_tenant e app.allow_*) não vazam
-- para fora da função que as liga.
--
-- Antes, bootstrap_company e outras funções faziam set_config(..., true), o que
-- vale até o fim da transação. Quem chamasse a função dentro de uma transação maior
-- continuava com o isolamento entre empresas desligado depois do retorno.
-- Com SET na definição, o Postgres restaura o valor anterior ao sair da função.
--
-- Rode uma vez no SQL Editor do Supabase. Pode rodar de novo sem problema.

DO $isolar$
DECLARE
  r record;
  f text;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'bootstrap_company',
        'seed_first_admin',
        'seed_company_access',
        'seed_price_visibility',
        'operator_authorize_company',
        'operator_enter_company',
        'operator_regenerate_invite',
        'operator_save_admin',
        'operator_set_company_blocked',
        'operator_update_company'
      )
  LOOP
    FOREACH f IN ARRAY ARRAY[
      'app.bypass_tenant',
      'app.allow_internal_company_update',
      'app.allow_operator_profile_move',
      'app.allow_operator_member_edit'
    ] LOOP
      EXECUTE format('ALTER FUNCTION %s SET %s = %L', r.sig, f, 'off');
    END LOOP;
  END LOOP;
END
$isolar$;

NOTIFY pgrst, 'reload schema';
