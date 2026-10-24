-- Palco — perda de material no evento (23/10/2026)
-- Cole só este arquivo no SQL Editor, depois dos patches anteriores.
-- Pode colar de novo. Não rode palco_supabase.sql.
-- Não apaga tabela, não dá TRUNCATE e não dá DELETE sem filtro.
--
-- Um aviso aberto aparece para administrador e gerente.
-- OK chama acknowledge_material_loss: baixa a quantidade no estoque,
-- grava o texto no evento e no próprio registro, e tira o aviso da lista.
-- O registro baixado permanece na tabela.

SELECT set_config('app.bypass_tenant', 'on', false);

CREATE TABLE IF NOT EXISTS material_losses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events (id) ON DELETE CASCADE,
  reason text NOT NULL,
  items jsonb NOT NULL,
  status text NOT NULL DEFAULT 'aberto',
  record_text text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

ALTER TABLE material_losses DROP CONSTRAINT IF EXISTS material_losses_status_check;
ALTER TABLE material_losses
  ADD CONSTRAINT material_losses_status_check
  CHECK (status IN ('aberto', 'baixado'));

ALTER TABLE material_losses DROP CONSTRAINT IF EXISTS material_losses_reason_check;
ALTER TABLE material_losses
  ADD CONSTRAINT material_losses_reason_check
  CHECK (char_length(btrim(reason)) >= 3);

CREATE INDEX IF NOT EXISTS material_losses_open_idx
  ON material_losses (company_id, status, created_at DESC);

DROP TRIGGER IF EXISTS trg_00_tenant ON material_losses;
CREATE TRIGGER trg_00_tenant
  BEFORE INSERT OR UPDATE ON material_losses
  FOR EACH ROW EXECUTE FUNCTION set_tenant_company();

ALTER TABLE material_losses ENABLE ROW LEVEL SECURITY;
ALTER TABLE material_losses FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS material_losses_select ON material_losses;
CREATE POLICY material_losses_select ON material_losses
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND has_role('admin', 'gerente')
  );

GRANT SELECT ON material_losses TO authenticated;

CREATE OR REPLACE FUNCTION report_material_loss(
  p_event uuid,
  p_reason text,
  p_items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_reason text := btrim(COALESCE(p_reason, ''));
  v_bucket jsonb := '{}'::jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_item jsonb;
  v_key text;
  v_eq uuid;
  v_qty integer;
  v_have integer;
  v_name text;
  v_id uuid;
BEGIN
  IF v_company IS NULL OR current_app_role() IS NULL OR current_app_role() = 'freelancer' THEN
    RAISE EXCEPTION 'Sem permissão para registrar perda';
  END IF;
  IF v_reason = '' OR char_length(v_reason) < 3 THEN
    RAISE EXCEPTION 'Informe o motivo da perda';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM events WHERE id = p_event AND company_id = v_company
  ) THEN
    RAISE EXCEPTION 'Evento não encontrado';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Selecione ao menos um item';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_eq := NULLIF(v_item->>'equipment_item_id', '')::uuid;
    v_qty := NULLIF(v_item->>'quantity', '')::integer;
    IF v_eq IS NULL OR v_qty IS NULL OR v_qty < 1 THEN
      RAISE EXCEPTION 'Item de perda inválido';
    END IF;
    v_bucket := jsonb_set(
      v_bucket,
      ARRAY[v_eq::text],
      to_jsonb(COALESCE((v_bucket ->> v_eq::text)::integer, 0) + v_qty),
      true
    );
  END LOOP;

  FOR v_key IN SELECT jsonb_object_keys(v_bucket)
  LOOP
    v_eq := v_key::uuid;
    v_qty := (v_bucket ->> v_key)::integer;
    SELECT ei.name, COALESCE((
      SELECT SUM(a.quantity)
      FROM event_allocations a
      WHERE a.event_id = p_event
        AND a.equipment_item_id = ei.id
        AND a.company_id = v_company
    ), 0)
    INTO v_name, v_have
    FROM equipment_items ei
    WHERE ei.id = v_eq AND ei.company_id = v_company;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'Equipamento não encontrado neste evento';
    END IF;
    IF v_qty > v_have THEN
      RAISE EXCEPTION 'A perda de % passa do que está alocado (%).', v_name, v_have;
    END IF;
    v_clean := v_clean || jsonb_build_array(jsonb_build_object(
      'equipment_item_id', v_eq,
      'name', v_name,
      'quantity', v_qty
    ));
  END LOOP;

  IF jsonb_array_length(v_clean) = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos um item';
  END IF;

  INSERT INTO material_losses (company_id, event_id, reason, items, status)
  VALUES (v_company, p_event, v_reason, v_clean, 'aberto')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION acknowledge_material_loss(p_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row material_losses%ROWTYPE;
  v_event events%ROWTYPE;
  v_item jsonb;
  v_eq uuid;
  v_qty integer;
  v_left integer;
  v_alloc record;
  v_lines text := '';
  v_text text;
BEGIN
  IF NOT has_role('admin', 'gerente') THEN
    RAISE EXCEPTION 'Só administrador e gerente confirmam a perda';
  END IF;

  SELECT * INTO v_row
  FROM material_losses
  WHERE id = p_id
    AND company_id = current_company_id()
    AND status = 'aberto';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Aviso não encontrado';
  END IF;

  SELECT * INTO v_event FROM events WHERE id = v_row.event_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_row.items)
  LOOP
    v_eq := (v_item->>'equipment_item_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_lines := v_lines || format(E'\n- %s× %s', v_qty, v_item->>'name');
    v_left := v_qty;

    FOR v_alloc IN
      SELECT id, quantity
      FROM event_allocations
      WHERE event_id = v_row.event_id
        AND equipment_item_id = v_eq
        AND company_id = v_row.company_id
      ORDER BY quantity DESC
    LOOP
      EXIT WHEN v_left <= 0;
      IF v_alloc.quantity <= v_left THEN
        DELETE FROM event_allocations WHERE id = v_alloc.id;
        v_left := v_left - v_alloc.quantity;
      ELSE
        UPDATE event_allocations
        SET quantity = quantity - v_left
        WHERE id = v_alloc.id;
        v_left := 0;
      END IF;
    END LOOP;

    UPDATE equipment_items
    SET quantity = quantity - v_qty
    WHERE id = v_eq
      AND company_id = v_row.company_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Equipamento não encontrado';
    END IF;
  END LOOP;

  v_text := format(
    E'Perda de material\nEvento: %s\nQuando: %s\nLocal: %s\nItens:%s\nMotivo: %s',
    v_event.title,
    to_char(v_event.starts_at, 'DD/MM/YYYY HH24:MI'),
    COALESCE(NULLIF(btrim(v_event.venue), ''), 'não informado'),
    v_lines,
    v_row.reason
  );

  UPDATE events
  SET notes = CASE
    WHEN notes IS NULL OR btrim(notes) = '' THEN v_text
    ELSE notes || E'\n\n' || v_text
  END
  WHERE id = v_event.id;

  UPDATE material_losses
  SET status = 'baixado',
      record_text = v_text,
      resolved_at = now()
  WHERE id = v_row.id;

  RETURN v_text;
END;
$$;

REVOKE ALL ON FUNCTION report_material_loss(uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION acknowledge_material_loss(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION report_material_loss(uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION acknowledge_material_loss(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
