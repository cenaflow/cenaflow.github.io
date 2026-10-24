-- Palco — escopo da agenda (23/10/2026)
--
-- Cole só este arquivo no SQL Editor, depois dos patches anteriores.
-- Pode colar de novo. Não rode palco_supabase.sql.
--
-- A matriz company_role_permissions ganha a caixa agenda_todos.
-- Ligada: o cargo vê todos os eventos da empresa.
-- Desligada: vê só os eventos em que está selecionado (event_freelancers,
-- a mesma regra do freelancer). O freelancer continua sempre nesse modo.
-- Quem já existia no banco nasce com a caixa ligada, menos o freelancer,
-- para não esconder a agenda atual.

CREATE OR REPLACE FUNCTION palco_default_grants(p_role text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_role
    WHEN 'admin' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":true,"estoque":true,"novo_item":true,"novo_freelancer":true,"novo_veiculo":true,"nova_manutencao":true,"novo_cliente":true,"novo_orcamento":true,"novo_lancamento":true,"freelancers":true,"veiculos":true,"clientes":true,"orcamentos":true,"financeiro":true,"equipe":true,"marca":true}'::jsonb
    WHEN 'gerente' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":true,"estoque":true,"novo_item":true,"novo_freelancer":true,"novo_veiculo":true,"nova_manutencao":true,"novo_cliente":true,"novo_orcamento":true,"novo_lancamento":true,"freelancers":true,"veiculos":true,"clientes":true,"orcamentos":true,"financeiro":true,"equipe":true,"marca":false}'::jsonb
    WHEN 'tecnico' THEN '{"inicio":true,"valores":false,"agenda":true,"agenda_todos":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":true,"veiculos":false,"clientes":false,"orcamentos":false,"financeiro":false,"equipe":false,"marca":false}'::jsonb
    WHEN 'financeiro' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":false,"orcamentos":true,"financeiro":true,"equipe":false,"marca":false}'::jsonb
    WHEN 'comercial' THEN '{"inicio":true,"valores":true,"agenda":true,"agenda_todos":true,"novo_evento":false,"estoque":true,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":true,"orcamentos":true,"financeiro":false,"equipe":false,"marca":false}'::jsonb
    ELSE '{"inicio":false,"valores":false,"agenda":true,"agenda_todos":false,"novo_evento":false,"estoque":false,"novo_item":false,"novo_freelancer":false,"novo_veiculo":false,"nova_manutencao":false,"novo_cliente":false,"novo_orcamento":false,"novo_lancamento":false,"freelancers":false,"veiculos":false,"clientes":false,"orcamentos":false,"financeiro":false,"equipe":false,"marca":false}'::jsonb
  END;
$$;

UPDATE company_role_permissions
SET flags = jsonb_set(flags, '{agenda_todos}', to_jsonb(role <> 'freelancer'), true)
WHERE NOT (flags ? 'agenda_todos');

CREATE OR REPLACE FUNCTION agenda_sees_all()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN current_app_role() IS NULL OR current_app_role() = 'freelancer' THEN false
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

DROP POLICY IF EXISTS events_select ON events;
CREATE POLICY events_select ON events
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      (current_app_role() IS DISTINCT FROM 'freelancer' AND agenda_sees_all())
      OR (
        freelancer_on_event(id)
        AND (current_app_role() IS DISTINCT FROM 'freelancer' OR freelancer_session_ok())
      )
    )
  );

DROP POLICY IF EXISTS event_allocations_select ON event_allocations;
CREATE POLICY event_allocations_select ON event_allocations
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      (current_app_role() IS DISTINCT FROM 'freelancer' AND agenda_sees_all())
      OR (
        freelancer_on_event(event_id)
        AND (current_app_role() IS DISTINCT FROM 'freelancer' OR freelancer_session_ok())
      )
    )
  );

DROP POLICY IF EXISTS event_freelancers_select ON event_freelancers;
CREATE POLICY event_freelancers_select ON event_freelancers
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      (current_app_role() IS DISTINCT FROM 'freelancer' AND agenda_sees_all())
      OR (
        freelancer_on_event(event_id)
        AND (current_app_role() IS DISTINCT FROM 'freelancer' OR freelancer_session_ok())
      )
    )
  );

DROP POLICY IF EXISTS event_transports_select ON event_transports;
CREATE POLICY event_transports_select ON event_transports
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      (current_app_role() IS DISTINCT FROM 'freelancer' AND agenda_sees_all())
      OR (
        freelancer_on_event(event_id)
        AND (current_app_role() IS DISTINCT FROM 'freelancer' OR freelancer_session_ok())
      )
    )
  );

REVOKE ALL ON FUNCTION agenda_sees_all() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION agenda_sees_all() TO authenticated;

NOTIFY pgrst, 'reload schema';
