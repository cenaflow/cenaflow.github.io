-- Palco — patch incremental de operação (22/10/2026, segunda leva)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez.
--
-- Inclui: responsável e horários de montagem/desmontagem no evento,
-- visibilidade de valores por papel, freelancers, veículos e manutenção,
-- custos de transporte do evento, linhas ocultas do orçamento
-- e disponibilidade de equipamento em lote.

SELECT set_config('app.bypass_tenant', 'on', true);

ALTER TABLE events ADD COLUMN IF NOT EXISTS responsible_name text;
ALTER TABLE events ADD COLUMN IF NOT EXISTS responsible_contact text;
ALTER TABLE events ADD COLUMN IF NOT EXISTS setup_at timestamptz;
ALTER TABLE events ADD COLUMN IF NOT EXISTS teardown_at timestamptz;

ALTER TABLE quote_items ADD COLUMN IF NOT EXISTS hidden boolean NOT NULL DEFAULT false;
ALTER TABLE quote_items ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'livre';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'quote_items_source_check'
  ) THEN
    ALTER TABLE quote_items
      ADD CONSTRAINT quote_items_source_check
      CHECK (source IN ('equipamento', 'freelancer', 'transporte', 'extra', 'livre'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS role_price_visibility (
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN (
    'admin', 'gerente', 'financeiro', 'estoque', 'tecnico', 'comercial', 'visualizador'
  )),
  can_see_prices boolean NOT NULL DEFAULT true,
  PRIMARY KEY (company_id, role)
);

CREATE TABLE IF NOT EXISTS freelancers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  job_title text,
  phone text,
  daily_rate numeric(12, 2) NOT NULL DEFAULT 0 CHECK (daily_rate >= 0),
  pix text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS freelancers_company_idx ON freelancers (company_id, name);

CREATE TABLE IF NOT EXISTS event_freelancers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events (id) ON DELETE CASCADE,
  freelancer_id uuid REFERENCES freelancers (id) ON DELETE SET NULL,
  name text NOT NULL,
  job_title text,
  days numeric(8, 2) NOT NULL DEFAULT 1 CHECK (days > 0),
  daily_rate numeric(12, 2) NOT NULL DEFAULT 0 CHECK (daily_rate >= 0),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS event_freelancers_event_idx ON event_freelancers (event_id);

CREATE TABLE IF NOT EXISTS vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  plate text NOT NULL,
  model text NOT NULL,
  consumption_km_per_liter numeric(8, 2) NOT NULL CHECK (consumption_km_per_liter > 0),
  fuel_type text NOT NULL CHECK (fuel_type IN ('gasolina', 'etanol', 'diesel', 'flex', 'gnv', 'eletrico')),
  odometer_km integer NOT NULL DEFAULT 0 CHECK (odometer_km >= 0),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, plate)
);

CREATE TABLE IF NOT EXISTS event_transports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events (id) ON DELETE CASCADE,
  vehicle_id uuid REFERENCES vehicles (id) ON DELETE SET NULL,
  plate text,
  model text,
  distance_km numeric(10, 1) NOT NULL DEFAULT 0 CHECK (distance_km >= 0),
  consumption_km_per_liter numeric(8, 2) NOT NULL CHECK (consumption_km_per_liter > 0),
  fuel_price numeric(12, 2) NOT NULL DEFAULT 0 CHECK (fuel_price >= 0),
  tolls numeric(12, 2) NOT NULL DEFAULT 0 CHECK (tolls >= 0),
  other_cost numeric(12, 2) NOT NULL DEFAULT 0 CHECK (other_cost >= 0),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS event_transports_event_idx ON event_transports (event_id);

CREATE TABLE IF NOT EXISTS vehicle_maintenance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  vehicle_id uuid NOT NULL REFERENCES vehicles (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  interval_km integer CHECK (interval_km IS NULL OR interval_km > 0),
  interval_days integer CHECK (interval_days IS NULL OR interval_days > 0),
  last_odometer_km integer CHECK (last_odometer_km IS NULL OR last_odometer_km >= 0),
  last_done_on date,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (interval_km IS NOT NULL OR interval_days IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS vehicle_maintenance_vehicle_idx ON vehicle_maintenance (vehicle_id);

CREATE OR REPLACE FUNCTION enforce_same_company_refs()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  IF TG_TABLE_NAME = 'equipment_items' THEN
    IF NEW.category_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM equipment_categories
      WHERE id = NEW.category_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Categoria de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'events' THEN
    IF NEW.client_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM clients
      WHERE id = NEW.client_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Cliente de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'maintenance_logs' THEN
    IF NOT EXISTS (
      SELECT 1 FROM equipment_items
      WHERE id = NEW.equipment_item_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Equipamento de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'quotes' THEN
    IF NEW.client_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM clients WHERE id = NEW.client_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Cliente de outra empresa';
    END IF;
    IF NEW.event_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM events WHERE id = NEW.event_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Evento de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'finance_transactions' THEN
    IF NEW.category_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM finance_categories
      WHERE id = NEW.category_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Categoria financeira de outra empresa';
    END IF;
    IF NEW.event_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM events WHERE id = NEW.event_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Evento de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'kit_items' THEN
    IF NOT EXISTS (
      SELECT 1 FROM kits WHERE id = NEW.kit_id AND company_id = NEW.company_id
    ) OR NOT EXISTS (
      SELECT 1 FROM equipment_items
      WHERE id = NEW.equipment_item_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Kit ou equipamento de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'quote_items' THEN
    IF NOT EXISTS (
      SELECT 1 FROM quotes WHERE id = NEW.quote_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Orçamento de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'event_freelancers' THEN
    IF NOT EXISTS (
      SELECT 1 FROM events WHERE id = NEW.event_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Evento de outra empresa';
    END IF;
    IF NEW.freelancer_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM freelancers WHERE id = NEW.freelancer_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Freelancer de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'event_transports' THEN
    IF NOT EXISTS (
      SELECT 1 FROM events WHERE id = NEW.event_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Evento de outra empresa';
    END IF;
    IF NEW.vehicle_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM vehicles WHERE id = NEW.vehicle_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Veículo de outra empresa';
    END IF;
  ELSIF TG_TABLE_NAME = 'vehicle_maintenance' THEN
    IF NOT EXISTS (
      SELECT 1 FROM vehicles WHERE id = NEW.vehicle_id AND company_id = NEW.company_id
    ) THEN
      RAISE EXCEPTION 'Veículo de outra empresa';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

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
    ('estoque', false),
    ('tecnico', false),
    ('visualizador', false)
  ) AS r(role, can_see)
  ON CONFLICT (company_id, role) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_price_visibility ON companies;
CREATE TRIGGER trg_seed_price_visibility
  AFTER INSERT ON companies
  FOR EACH ROW EXECUTE FUNCTION seed_price_visibility();

INSERT INTO role_price_visibility (company_id, role, can_see_prices)
SELECT c.id, r.role, r.can_see
FROM companies c
CROSS JOIN (VALUES
  ('admin', true),
  ('gerente', true),
  ('financeiro', true),
  ('comercial', true),
  ('estoque', false),
  ('tecnico', false),
  ('visualizador', false)
) AS r(role, can_see)
ON CONFLICT (company_id, role) DO NOTHING;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'role_price_visibility', 'freelancers', 'event_freelancers',
    'vehicles', 'event_transports', 'vehicle_maintenance'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_00_tenant ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_00_tenant BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_tenant_company()',
      t
    );
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['freelancers', 'vehicles', 'vehicle_maintenance']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_90_touch ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_90_touch BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION touch_updated_at()',
      t
    );
  END LOOP;

  FOREACH t IN ARRAY ARRAY['event_freelancers', 'event_transports', 'vehicle_maintenance']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_05_refs ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_05_refs BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION enforce_same_company_refs()',
      t
    );
  END LOOP;
END $$;

DROP POLICY IF EXISTS role_price_visibility_select ON role_price_visibility;
CREATE POLICY role_price_visibility_select ON role_price_visibility
  FOR SELECT TO authenticated
  USING (company_id = current_company_id());

DROP POLICY IF EXISTS role_price_visibility_write ON role_price_visibility;
CREATE POLICY role_price_visibility_write ON role_price_visibility
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin'));

DROP POLICY IF EXISTS freelancers_select ON freelancers;
CREATE POLICY freelancers_select ON freelancers
  FOR SELECT TO authenticated
  USING (company_id = current_company_id());

DROP POLICY IF EXISTS freelancers_write ON freelancers;
CREATE POLICY freelancers_write ON freelancers
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

DROP POLICY IF EXISTS event_freelancers_select ON event_freelancers;
CREATE POLICY event_freelancers_select ON event_freelancers
  FOR SELECT TO authenticated
  USING (company_id = current_company_id());

DROP POLICY IF EXISTS event_freelancers_write ON event_freelancers;
CREATE POLICY event_freelancers_write ON event_freelancers
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

DROP POLICY IF EXISTS vehicles_select ON vehicles;
CREATE POLICY vehicles_select ON vehicles
  FOR SELECT TO authenticated
  USING (company_id = current_company_id());

DROP POLICY IF EXISTS vehicles_write ON vehicles;
CREATE POLICY vehicles_write ON vehicles
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

DROP POLICY IF EXISTS event_transports_select ON event_transports;
CREATE POLICY event_transports_select ON event_transports
  FOR SELECT TO authenticated
  USING (company_id = current_company_id());

DROP POLICY IF EXISTS event_transports_write ON event_transports;
CREATE POLICY event_transports_write ON event_transports
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

DROP POLICY IF EXISTS vehicle_maintenance_select ON vehicle_maintenance;
CREATE POLICY vehicle_maintenance_select ON vehicle_maintenance
  FOR SELECT TO authenticated
  USING (company_id = current_company_id());

DROP POLICY IF EXISTS vehicle_maintenance_write ON vehicle_maintenance;
CREATE POLICY vehicle_maintenance_write ON vehicle_maintenance
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial', 'tecnico', 'estoque'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial', 'tecnico', 'estoque'));

GRANT SELECT, INSERT, UPDATE, DELETE ON
  role_price_visibility, freelancers, event_freelancers, vehicles, event_transports, vehicle_maintenance
TO authenticated;

CREATE OR REPLACE FUNCTION equipment_availability_bulk(
  p_starts timestamptz,
  p_ends timestamptz
)
RETURNS TABLE (item_id uuid, free_qty integer)
LANGUAGE sql
STABLE
SET search_path = public, extensions
AS $$
  SELECT ei.id,
    CASE
      WHEN ei.status IN ('manutencao', 'baixado') THEN 0
      ELSE ei.quantity - COALESCE((
        SELECT SUM(a.quantity)::integer
        FROM event_allocations a
        JOIN events e ON e.id = a.event_id
        WHERE a.equipment_item_id = ei.id
          AND e.status <> 'cancelado'
          AND a.starts_at < p_ends
          AND a.ends_at > p_starts
      ), 0)
    END::integer
  FROM equipment_items ei
  WHERE ei.company_id = current_company_id()
$$;

GRANT EXECUTE ON FUNCTION equipment_availability_bulk(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION seed_price_visibility() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_same_company_refs() TO authenticated;

NOTIFY pgrst, 'reload schema';
