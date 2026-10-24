-- Palco — patch: as flags internas (app.bypass_tenant e app.allow_*) não vazam
-- para fora da função que as liga.
--
-- Antes, bootstrap_company e outras funções faziam set_config(..., true), o que
-- vale até o fim da transação. Quem chamasse a função dentro de uma transação maior
-- continuava com o isolamento entre empresas desligado depois do retorno.
--
-- No Supabase o papel postgres não é superusuário e não pode usar
-- ALTER FUNCTION ... SET app.* (erro 42501). Então:
--  * cada função RPC vira <nome>__impl (sem EXECUTE para clientes) e ganha uma
--    casca com o mesmo nome, assinatura, SECURITY DEFINER e grants, que guarda o
--    valor das flags, chama a __impl e devolve as flags ao valor anterior;
--  * os dois gatilhos (seed_company_access, seed_price_visibility) são
--    reescritos para devolver a flag ao valor anterior antes do RETURN.
-- Em caso de erro, o Postgres já desfaz o set_config(..., true) junto com a
-- transação/savepoint que falhou, então o caminho de erro também fica limpo.
--
-- Rode no SQL Editor do Supabase. Pode rodar de novo sem problema: se um patch
-- posterior recriar a função original, ela é embrulhada de novo.

-- Gatilhos ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION seed_price_visibility()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_prev text := current_setting('app.bypass_tenant', true);
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
  PERFORM set_config('app.bypass_tenant', COALESCE(v_prev, 'off'), true);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION seed_company_access()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prev text := current_setting('app.bypass_tenant', true);
BEGIN
  BEGIN
    PERFORM set_config('app.bypass_tenant', 'on', true);
    INSERT INTO company_role_permissions (company_id, role, flags)
    SELECT NEW.id, r.role, palco_default_grants(r.role)
    FROM (
      VALUES ('admin'), ('gerente'), ('financeiro'), ('tecnico'), ('comercial'), ('freelancer')
    ) AS r(role)
    ON CONFLICT (company_id, role) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- comportamento antigo: falha aqui não impede criar a empresa
  END;
  PERFORM set_config('app.bypass_tenant', COALESCE(v_prev, 'off'), true);
  RETURN NEW;
END;
$$;

-- RPCs: casca que restaura as flags ---------------------------------------

DO $isolar$
DECLARE
  v_names text[] := ARRAY[
    'bootstrap_company', 'seed_first_admin',
    'operator_authorize_company', 'operator_enter_company',
    'operator_regenerate_invite', 'operator_save_admin',
    'operator_set_company_blocked', 'operator_update_company'
  ];
  v_flags constant text := $f$ARRAY[
      current_setting('app.bypass_tenant', true),
      current_setting('app.allow_internal_company_update', true),
      current_setting('app.allow_operator_profile_move', true),
      current_setting('app.allow_operator_member_edit', true)]$f$;
  v_restore constant text := $r$
  PERFORM set_config('app.bypass_tenant', COALESCE(v_prev[1], 'off'), true);
  PERFORM set_config('app.allow_internal_company_update', COALESCE(v_prev[2], 'off'), true);
  PERFORM set_config('app.allow_operator_profile_move', COALESCE(v_prev[3], 'off'), true);
  PERFORM set_config('app.allow_operator_member_edit', COALESCE(v_prev[4], 'off'), true);$r$;
  r record;
  v_impl regprocedure;
  v_args text;
  v_types text;
  v_call text;
  v_result text;
  v_body text;
  g record;
  v_role text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, p.pronargs, p.proargtypes,
           pg_get_function_identity_arguments(p.oid) AS ident,
           pg_get_function_arguments(p.oid) AS args,
           pg_get_function_result(p.oid) AS result,
           p.proretset,
           COALESCE(obj_description(p.oid, 'pg_proc'), '') AS cmt
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = ANY (v_names)
  LOOP
    SELECT i.oid::regprocedure INTO v_impl
    FROM pg_proc i
    WHERE i.pronamespace = 'public'::regnamespace
      AND i.proname = r.proname || '__impl'
      AND i.proargtypes = r.proargtypes;

    IF r.cmt LIKE 'palco:flag_guard%' AND v_impl IS NOT NULL THEN
      CONTINUE; -- já embrulhada
    END IF;

    -- Função original nova (primeira vez, ou recriada por patch posterior).
    IF v_impl IS NOT NULL THEN
      EXECUTE format('DROP FUNCTION %s', v_impl);
    END IF;
    EXECUTE format('ALTER FUNCTION public.%I(%s) RENAME TO %I',
                   r.proname, r.ident, r.proname || '__impl');
    v_impl := r.oid::regprocedure;

    SELECT string_agg('$' || i, ', ' ORDER BY i) INTO v_call
    FROM generate_series(1, r.pronargs) AS i;
    v_call := format('public.%I(%s)', r.proname || '__impl', COALESCE(v_call, ''));

    IF r.proretset THEN
      v_body := format(E'DECLARE\n  v_prev text[] := %s;\nBEGIN\n  RETURN QUERY SELECT * FROM %s;%s\n  RETURN;\nEND;',
                       v_flags, v_call, v_restore);
    ELSIF r.result = 'void' THEN
      v_body := format(E'DECLARE\n  v_prev text[] := %s;\nBEGIN\n  PERFORM %s;%s\nEND;',
                       v_flags, v_call, v_restore);
    ELSE
      v_body := format(E'DECLARE\n  v_prev text[] := %s;\n  v_out %s;\nBEGIN\n  v_out := %s;%s\n  RETURN v_out;\nEND;',
                       v_flags, r.result, v_call, v_restore);
    END IF;

    EXECUTE format(
      'CREATE FUNCTION public.%I(%s) RETURNS %s LANGUAGE plpgsql SECURITY DEFINER '
      'SET search_path = public AS %L',
      r.proname, r.args, r.result, v_body);
    EXECUTE format('COMMENT ON FUNCTION public.%I(%s) IS %L',
                   r.proname, r.ident, 'palco:flag_guard — chama ' || r.proname || '__impl e restaura app.*');

    -- Mesmos grants da original; a __impl fica só para o dono.
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC', r.proname, r.ident);
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM %I', r.proname, r.ident, v_role);
      END IF;
    END LOOP;
    FOR g IN
      SELECT a.grantee, a.privilege_type
      FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
      WHERE p.oid = r.oid AND a.grantee <> p.proowner
    LOOP
      IF g.grantee = 0 THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO PUBLIC', r.proname, r.ident);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_impl);
      ELSE
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO %I',
                       r.proname, r.ident, g.grantee::regrole::text);
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', v_impl, g.grantee::regrole::text);
      END IF;
    END LOOP;
  END LOOP;
END
$isolar$;

NOTIFY pgrst, 'reload schema';
