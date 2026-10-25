-- Cenaflow — instalação única no SQL Editor do Supabase.
-- Cole este arquivo inteiro e execute uma vez, num projeto ainda sem as tabelas do Cenaflow.
--
-- Depois, no painel:
--   Authentication → Users → Add user → Create new user
--   Preencha e-mail e senha e marque "Auto Confirm User".
--   Copie o UID.
--
-- Volte ao SQL Editor e rode só isto (troque os quatro textos):
--
--   SELECT * FROM seed_first_admin(
--     'COLE-O-UID',
--     'seu-email@empresa.com',
--     'Seu Nome',
--     'Nome da Empresa'
--   );
--
-- A coluna invite_code é o convite do funcionário fixo. Quem entrar com ele
-- começa como freelancer; o administrador muda o papel em Equipe.
-- Não rode este arquivo de novo: a tabela companies passa a existir.

DO $palco_guard$
BEGIN
  IF to_regclass('public.companies') IS NOT NULL THEN
    RAISE EXCEPTION
      'O Cenaflow já está instalado. Não rode o arquivo inteiro de novo. Para ligar o primeiro admin, execute só SELECT * FROM seed_first_admin(...).';
  END IF;
END
$palco_guard$;

-- Palco — schema portátil (Postgres 15+).
-- Não depende de auth.users, storage.buckets nem de papéis do Supabase.
-- A sessão da API é lida de request.jwt.claims / request.jwt.claim.sub,
-- que o PostgREST (Supabase ou self-hosted) preenche a partir do JWT.
-- Rode em seguida 20261022000200_rls.sql antes de expor a API.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Identidade da sessão (JWT). Compatível com Supabase e PostgREST.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION current_jwt_sub()
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public, extensions
AS $$
DECLARE
  claims text;
  sub text;
BEGIN
  sub := NULLIF(current_setting('request.jwt.claim.sub', true), '');
  IF sub IS NOT NULL THEN
    RETURN sub;
  END IF;
  claims := NULLIF(current_setting('request.jwt.claims', true), '');
  IF claims IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN NULLIF(claims::json->>'sub', '');
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
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
    SELECT company_id
    FROM profiles
    WHERE auth_subject = current_jwt_sub()
      AND active
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
    SELECT role
    FROM profiles
    WHERE auth_subject = current_jwt_sub()
      AND active
    LIMIT 1
  );
END;
$$;

CREATE OR REPLACE FUNCTION has_role(VARIADIC p_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, extensions
AS $$
  SELECT current_app_role() = ANY (p_roles)
$$;

-- ---------------------------------------------------------------------------
-- Empresas e usuários
-- auth_subject guarda o "sub" do provedor de identidade (texto, não uuid),
-- para trocar Supabase Auth / GoTrue / outro IdP sem reescrever o negócio.
-- ---------------------------------------------------------------------------

CREATE TABLE companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) >= 2),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  logo_url text,
  primary_color text NOT NULL DEFAULT '#0f6e6b' CHECK (primary_color ~ '^#[0-9a-f]{6}$'),
  secondary_color text NOT NULL DEFAULT '#e8a838' CHECK (secondary_color ~ '^#[0-9a-f]{6}$'),
  storage_quota_bytes bigint NOT NULL DEFAULT 209715200 CHECK (storage_quota_bytes >= 0),
  storage_used_bytes bigint NOT NULL DEFAULT 0 CHECK (storage_used_bytes >= 0),
  invite_code text NOT NULL UNIQUE CHECK (invite_code ~ '^[A-Z0-9]{6,16}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_subject text NOT NULL UNIQUE,
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  full_name text NOT NULL CHECK (char_length(btrim(full_name)) >= 2),
  email text NOT NULL,
  role text NOT NULL CHECK (role IN (
    'admin', 'gerente', 'financeiro', 'estoque', 'tecnico', 'comercial', 'visualizador'
  )),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, email)
);

CREATE INDEX profiles_company_idx ON profiles (company_id);

-- ---------------------------------------------------------------------------
-- Estoque
-- ---------------------------------------------------------------------------

CREATE TABLE equipment_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name)
);

CREATE TABLE equipment_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  category_id uuid REFERENCES equipment_categories (id) ON DELETE SET NULL,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  description text,
  serial_number text,
  qr_code text,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  status text NOT NULL DEFAULT 'disponivel' CHECK (status IN (
    'disponivel', 'em_uso', 'manutencao', 'baixado'
  )),
  daily_rate numeric(12, 2) NOT NULL DEFAULT 0 CHECK (daily_rate >= 0),
  photo_url text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX equipment_items_serial_uq
  ON equipment_items (company_id, serial_number)
  WHERE serial_number IS NOT NULL AND serial_number <> '';

CREATE INDEX equipment_items_company_idx ON equipment_items (company_id, name);

CREATE TABLE kits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  description text,
  daily_rate numeric(12, 2) NOT NULL DEFAULT 0 CHECK (daily_rate >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name)
);

CREATE TABLE kit_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  kit_id uuid NOT NULL REFERENCES kits (id) ON DELETE CASCADE,
  equipment_item_id uuid NOT NULL REFERENCES equipment_items (id) ON DELETE RESTRICT,
  quantity integer NOT NULL CHECK (quantity > 0),
  UNIQUE (kit_id, equipment_item_id)
);

CREATE TABLE consumables (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  unit text NOT NULL DEFAULT 'un',
  quantity numeric(12, 2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  min_quantity numeric(12, 2) NOT NULL DEFAULT 0 CHECK (min_quantity >= 0),
  unit_cost numeric(12, 2) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  notes text,
  low_stock boolean GENERATED ALWAYS AS (quantity <= min_quantity) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name)
);

CREATE TABLE maintenance_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  equipment_item_id uuid NOT NULL REFERENCES equipment_items (id) ON DELETE CASCADE,
  description text NOT NULL CHECK (char_length(btrim(description)) >= 1),
  cost numeric(12, 2) NOT NULL DEFAULT 0 CHECK (cost >= 0),
  performed_at date NOT NULL DEFAULT CURRENT_DATE,
  status text NOT NULL DEFAULT 'aberta' CHECK (status IN ('aberta', 'em_andamento', 'concluida')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX maintenance_logs_item_idx ON maintenance_logs (equipment_item_id, performed_at DESC);

CREATE TABLE purchase_needs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  title text NOT NULL CHECK (char_length(btrim(title)) >= 1),
  description text,
  quantity numeric(12, 2) NOT NULL DEFAULT 1 CHECK (quantity > 0),
  estimated_cost numeric(12, 2) NOT NULL DEFAULT 0 CHECK (estimated_cost >= 0),
  status text NOT NULL DEFAULT 'aberta' CHECK (status IN (
    'aberta', 'aprovada', 'comprada', 'cancelada'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Clientes, agenda, orçamentos, financeiro
-- ---------------------------------------------------------------------------

CREATE TABLE clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) >= 1),
  email text,
  phone text,
  document text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX clients_company_idx ON clients (company_id, name);

CREATE TABLE events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  client_id uuid REFERENCES clients (id) ON DELETE SET NULL,
  title text NOT NULL CHECK (char_length(btrim(title)) >= 1),
  event_type text NOT NULL CHECK (event_type IN (
    'casamento', 'formatura', 'corporativo', 'aniversario', 'feira', 'show', 'outros'
  )),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  venue text,
  notes text,
  status text NOT NULL DEFAULT 'orcamento' CHECK (status IN (
    'orcamento', 'confirmado', 'em_andamento', 'concluido', 'cancelado'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);

CREATE INDEX events_range_idx ON events (company_id, starts_at, ends_at);

CREATE TABLE event_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES events (id) ON DELETE CASCADE,
  equipment_item_id uuid NOT NULL REFERENCES equipment_items (id) ON DELETE RESTRICT,
  quantity integer NOT NULL CHECK (quantity > 0),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);

CREATE INDEX event_allocations_item_idx
  ON event_allocations (equipment_item_id, starts_at, ends_at);
CREATE INDEX event_allocations_event_idx ON event_allocations (event_id);

CREATE TABLE quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  client_id uuid REFERENCES clients (id) ON DELETE SET NULL,
  event_id uuid REFERENCES events (id) ON DELETE SET NULL,
  number text NOT NULL,
  status text NOT NULL DEFAULT 'rascunho' CHECK (status IN (
    'rascunho', 'enviado', 'aprovado', 'recusado'
  )),
  discount numeric(12, 2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  notes text,
  valid_until date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, number)
);

CREATE TABLE quote_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  quote_id uuid NOT NULL REFERENCES quotes (id) ON DELETE CASCADE,
  description text NOT NULL,
  quantity numeric(12, 2) NOT NULL CHECK (quantity > 0),
  unit_price numeric(12, 2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE finance_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('receita', 'despesa')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name, kind)
);

CREATE TABLE finance_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  category_id uuid REFERENCES finance_categories (id) ON DELETE SET NULL,
  event_id uuid REFERENCES events (id) ON DELETE SET NULL,
  description text NOT NULL,
  amount numeric(12, 2) NOT NULL CHECK (amount >= 0),
  kind text NOT NULL CHECK (kind IN ('receita', 'despesa')),
  occurred_on date NOT NULL DEFAULT CURRENT_DATE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX finance_transactions_date_idx
  ON finance_transactions (company_id, occurred_on DESC);

-- Metadados dos arquivos. O binário fica no armazenamento (interface do app).
CREATE TABLE stored_files (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  path text NOT NULL UNIQUE,
  bytes bigint NOT NULL CHECK (bytes > 0),
  content_type text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Gatilhos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION set_tenant_company()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  IF current_setting('app.bypass_tenant', true) = 'on' THEN
    IF NEW.company_id IS NULL THEN
      RAISE EXCEPTION 'company_id obrigatório na importação';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.company_id := current_company_id();
  ELSIF NEW.company_id IS DISTINCT FROM OLD.company_id THEN
    RAISE EXCEPTION 'company_id não pode ser alterado';
  END IF;

  IF NEW.company_id IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  RETURN NEW;
END;
$$;

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
     OR NEW.id IS DISTINCT FROM OLD.id THEN
    IF current_setting('app.allow_internal_company_update', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'Campos internos da empresa só mudam por funções do sistema';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

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
     OR NEW.company_id IS DISTINCT FROM OLD.company_id
     OR NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Identidade do usuário não pode ser alterada';
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

CREATE OR REPLACE FUNCTION normalize_equipment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
BEGIN
  IF NEW.serial_number IS NOT NULL AND btrim(NEW.serial_number) = '' THEN
    NEW.serial_number := NULL;
  END IF;
  IF NEW.qr_code IS NULL OR btrim(NEW.qr_code) = '' THEN
    NEW.qr_code := 'palco:equip:' || NEW.id::text;
  END IF;
  RETURN NEW;
END;
$$;

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
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_allocation_availability()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  v_qty integer;
  v_status text;
  v_company uuid;
  v_event_status text;
  v_allocated integer;
BEGIN
  SELECT quantity, status, company_id
    INTO v_qty, v_status, v_company
  FROM equipment_items
  WHERE id = NEW.equipment_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Equipamento não encontrado';
  END IF;
  IF NEW.company_id IS DISTINCT FROM v_company THEN
    RAISE EXCEPTION 'Equipamento de outra empresa';
  END IF;
  IF v_status IN ('manutencao', 'baixado') THEN
    RAISE EXCEPTION 'Equipamento indisponível (manutenção ou baixado)';
  END IF;

  SELECT status INTO v_event_status
  FROM events
  WHERE id = NEW.event_id AND company_id = NEW.company_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento não encontrado';
  END IF;
  IF v_event_status = 'cancelado' THEN
    RAISE EXCEPTION 'Evento cancelado não recebe equipamento';
  END IF;

  SELECT COALESCE(SUM(a.quantity), 0) INTO v_allocated
  FROM event_allocations a
  JOIN events e ON e.id = a.event_id
  WHERE a.equipment_item_id = NEW.equipment_item_id
    AND a.company_id = NEW.company_id
    AND e.status <> 'cancelado'
    AND a.starts_at < NEW.ends_at
    AND a.ends_at > NEW.starts_at
    AND (TG_OP = 'INSERT' OR a.id <> NEW.id);

  IF v_allocated + NEW.quantity > v_qty THEN
    RAISE EXCEPTION 'Conflito de disponibilidade: % unidade(s) livre(s) no período, % solicitada(s)',
      GREATEST(v_qty - v_allocated, 0), NEW.quantity;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION enforce_equipment_quantity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  v_needed integer;
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;
  IF NEW.quantity = OLD.quantity AND NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status IN ('manutencao', 'baixado')
     AND OLD.status IS DISTINCT FROM NEW.status
     AND EXISTS (
       SELECT 1
       FROM event_allocations a
       JOIN events e ON e.id = a.event_id
       WHERE a.equipment_item_id = NEW.id
         AND e.status <> 'cancelado'
         AND a.ends_at > now()
     ) THEN
    RAISE EXCEPTION 'Há alocações futuras para este equipamento. Cancele-as antes de marcar manutenção ou baixa.';
  END IF;

  IF NEW.quantity < OLD.quantity THEN
    SELECT COALESCE(MAX(total), 0) INTO v_needed
    FROM (
      SELECT (
        SELECT COALESCE(SUM(a2.quantity), 0)
        FROM event_allocations a2
        JOIN events e2 ON e2.id = a2.event_id
        WHERE a2.equipment_item_id = NEW.id
          AND e2.status <> 'cancelado'
          AND a2.starts_at < a.ends_at
          AND a2.ends_at > a.starts_at
      ) AS total
      FROM event_allocations a
      JOIN events e ON e.id = a.event_id
      WHERE a.equipment_item_id = NEW.id
        AND e.status <> 'cancelado'
    ) s;
    IF v_needed > NEW.quantity THEN
      RAISE EXCEPTION 'A quantidade fica abaixo do que já está alocado no mesmo período (%).', v_needed;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_00_protect_company
  BEFORE UPDATE ON companies
  FOR EACH ROW EXECUTE FUNCTION protect_company_storage();

CREATE TRIGGER trg_90_touch_company
  BEFORE UPDATE ON companies
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER trg_00_protect_profile
  BEFORE INSERT OR UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION protect_profile();

CREATE TRIGGER trg_90_touch_profile
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'equipment_categories', 'equipment_items', 'kits', 'kit_items', 'consumables',
    'maintenance_logs', 'purchase_needs', 'clients', 'events', 'event_allocations',
    'quotes', 'quote_items', 'finance_categories', 'finance_transactions', 'stored_files'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_00_tenant BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_tenant_company()',
      t
    );
  END LOOP;

  FOREACH t IN ARRAY ARRAY[
    'equipment_categories', 'equipment_items', 'kits', 'consumables',
    'maintenance_logs', 'purchase_needs', 'clients', 'events', 'quotes',
    'finance_categories', 'finance_transactions'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_90_touch BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION touch_updated_at()',
      t
    );
  END LOOP;

  FOREACH t IN ARRAY ARRAY[
    'equipment_items', 'events', 'maintenance_logs', 'quotes',
    'finance_transactions', 'kit_items', 'quote_items'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_05_refs BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION enforce_same_company_refs()',
      t
    );
  END LOOP;
END $$;

CREATE TRIGGER trg_10_normalize_equipment
  BEFORE INSERT OR UPDATE ON equipment_items
  FOR EACH ROW EXECUTE FUNCTION normalize_equipment();

CREATE TRIGGER trg_20_equipment_quantity
  BEFORE UPDATE ON equipment_items
  FOR EACH ROW EXECUTE FUNCTION enforce_equipment_quantity();

CREATE TRIGGER trg_10_allocation_availability
  BEFORE INSERT OR UPDATE ON event_allocations
  FOR EACH ROW EXECUTE FUNCTION enforce_allocation_availability();

-- ---------------------------------------------------------------------------
-- Funções de negócio expostas à API (PostgREST / Supabase RPC)
-- ---------------------------------------------------------------------------

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
  INSERT INTO companies (name, slug, primary_color, secondary_color, invite_code)
  VALUES (btrim(p_name), v_slug, lower(p_primary), lower(p_secondary), v_code)
  RETURNING id INTO v_company;

  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'admin');

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

CREATE OR REPLACE FUNCTION join_company(
  p_code text,
  p_full_name text,
  p_email text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_company uuid;
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
  SELECT id INTO v_company
  FROM companies
  WHERE invite_code = upper(btrim(COALESCE(p_code, '')));
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Código de convite inválido';
  END IF;
  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'visualizador');
  RETURN v_company;
END;
$$;

CREATE OR REPLACE FUNCTION regenerate_invite_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_code text;
  tries integer := 0;
BEGIN
  IF current_app_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Apenas administradores geram um novo código';
  END IF;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
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
  UPDATE companies SET invite_code = v_code WHERE id = v_company;
  RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION reserve_storage(p_bytes bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_quota bigint;
  v_used bigint;
BEGIN
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  IF p_bytes IS NULL OR p_bytes <= 0 THEN
    RAISE EXCEPTION 'Tamanho de arquivo inválido';
  END IF;
  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  SELECT storage_quota_bytes, storage_used_bytes
    INTO v_quota, v_used
  FROM companies
  WHERE id = v_company
  FOR UPDATE;
  IF v_used + p_bytes > v_quota THEN
    RAISE EXCEPTION 'Cota de armazenamento da empresa excedida';
  END IF;
  UPDATE companies
  SET storage_used_bytes = storage_used_bytes + p_bytes
  WHERE id = v_company;
END;
$$;

CREATE OR REPLACE FUNCTION release_storage(p_bytes bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
BEGIN
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  IF p_bytes IS NULL OR p_bytes < 0 THEN
    RAISE EXCEPTION 'Tamanho de arquivo inválido';
  END IF;
  PERFORM set_config('app.allow_internal_company_update', 'on', true);
  UPDATE companies
  SET storage_used_bytes = GREATEST(storage_used_bytes - p_bytes, 0)
  WHERE id = v_company;
END;
$$;

CREATE OR REPLACE FUNCTION equipment_availability(
  p_item_id uuid,
  p_starts timestamptz,
  p_ends timestamptz,
  p_exclude uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public, extensions
AS $$
  SELECT CASE
    WHEN ei.status IN ('manutencao', 'baixado') THEN 0
    ELSE ei.quantity - COALESCE((
      SELECT SUM(a.quantity)::integer
      FROM event_allocations a
      JOIN events e ON e.id = a.event_id
      WHERE a.equipment_item_id = ei.id
        AND e.status <> 'cancelado'
        AND a.starts_at < p_ends
        AND a.ends_at > p_starts
        AND (p_exclude IS NULL OR a.id <> p_exclude)
    ), 0)
  END::integer
  FROM equipment_items ei
  WHERE ei.id = p_item_id
    AND ei.company_id = current_company_id()
$$;

CREATE OR REPLACE FUNCTION allocate_kit(
  p_event_id uuid,
  p_kit_id uuid,
  p_multiplier integer DEFAULT 1
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_event events%ROWTYPE;
  v_count integer := 0;
  r record;
BEGIN
  IF NOT has_role('admin', 'gerente', 'comercial') THEN
    RAISE EXCEPTION 'Sem permissão para alocar equipamento';
  END IF;
  IF p_multiplier IS NULL OR p_multiplier < 1 THEN
    RAISE EXCEPTION 'Quantidade inválida';
  END IF;
  SELECT * INTO v_event
  FROM events
  WHERE id = p_event_id AND company_id = v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento não encontrado';
  END IF;
  IF v_event.status = 'cancelado' THEN
    RAISE EXCEPTION 'Evento cancelado não recebe equipamento';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM kits WHERE id = p_kit_id AND company_id = v_company) THEN
    RAISE EXCEPTION 'Kit não encontrado';
  END IF;

  FOR r IN
    SELECT ki.equipment_item_id, ki.quantity
    FROM kit_items ki
    WHERE ki.kit_id = p_kit_id AND ki.company_id = v_company
  LOOP
    INSERT INTO event_allocations (event_id, equipment_item_id, quantity, starts_at, ends_at)
    VALUES (
      p_event_id,
      r.equipment_item_id,
      r.quantity * p_multiplier,
      v_event.starts_at,
      v_event.ends_at
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Kit vazio ou não encontrado';
  END IF;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION align_allocations(p_event_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_event events%ROWTYPE;
  v_count integer;
BEGIN
  IF NOT has_role('admin', 'gerente', 'comercial') THEN
    RAISE EXCEPTION 'Sem permissão para alocar equipamento';
  END IF;
  SELECT * INTO v_event
  FROM events
  WHERE id = p_event_id AND company_id = v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Evento não encontrado';
  END IF;
  UPDATE event_allocations
  SET starts_at = v_event.starts_at,
      ends_at = v_event.ends_at
  WHERE event_id = p_event_id
    AND company_id = v_company;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION replace_kit_items(p_kit_id uuid, p_items jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  r jsonb;
  v_item uuid;
  v_qty integer;
BEGIN
  IF NOT has_role('admin', 'gerente', 'estoque') THEN
    RAISE EXCEPTION 'Sem permissão para alterar kits';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM kits WHERE id = p_kit_id AND company_id = v_company) THEN
    RAISE EXCEPTION 'Kit não encontrado';
  END IF;
  DELETE FROM kit_items WHERE kit_id = p_kit_id AND company_id = v_company;
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    v_item := (r->>'equipment_item_id')::uuid;
    v_qty := COALESCE((r->>'quantity')::integer, 0);
    IF v_qty < 1 THEN
      RAISE EXCEPTION 'Quantidade inválida no kit';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM equipment_items WHERE id = v_item AND company_id = v_company
    ) THEN
      RAISE EXCEPTION 'Equipamento do kit não encontrado';
    END IF;
    INSERT INTO kit_items (kit_id, equipment_item_id, quantity)
    VALUES (p_kit_id, v_item, v_qty);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION next_quote_number()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_n integer;
BEGIN
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  -- O maior sufixo evita repetir ORC-0002 depois que um rascunho anterior é excluído.
  -- count(*) + 1 colidia com o número que ainda existia.
  SELECT COALESCE(MAX(
    CASE
      WHEN number ~ '^ORC-[0-9]+$' THEN substring(number FROM 5)::integer
      ELSE NULL
    END
  ), 0) + 1
  INTO v_n
  FROM quotes
  WHERE company_id = v_company;
  RETURN 'ORC-' || lpad(v_n::text, 4, '0');
END;
$$;

COMMENT ON TABLE companies IS 'Empresa locatária. Branding e cota de arquivos ficam aqui.';
COMMENT ON TABLE profiles IS 'Usuário da aplicação. auth_subject liga ao provedor de identidade.';
COMMENT ON COLUMN profiles.auth_subject IS 'Claim sub do JWT. Não é chave estrangeira de auth.users.';
COMMENT ON TABLE event_allocations IS 'Reserva de equipamento. O gatilho impede conflito de quantidade no período.';
COMMENT ON COLUMN companies.storage_quota_bytes IS 'Cota por empresa. O padrão é 200 MB. O operador do banco altera via SQL.';

-- Palco — isolamento por empresa e papéis.
-- Os papéis anon/authenticated são criados só se ainda não existirem,
-- para funcionar no Supabase (já existem) e num Postgres comum.
-- Aplique este arquivo depois do schema, antes de expor a API.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

GRANT EXECUTE ON FUNCTION current_jwt_sub() TO authenticated;
GRANT EXECUTE ON FUNCTION current_company_id() TO authenticated;
GRANT EXECUTE ON FUNCTION current_app_role() TO authenticated;
GRANT EXECUTE ON FUNCTION has_role(text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION touch_updated_at() TO authenticated;
GRANT EXECUTE ON FUNCTION set_tenant_company() TO authenticated;
GRANT EXECUTE ON FUNCTION protect_company_storage() TO authenticated;
GRANT EXECUTE ON FUNCTION protect_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION normalize_equipment() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_same_company_refs() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_allocation_availability() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_equipment_quantity() TO authenticated;

GRANT EXECUTE ON FUNCTION bootstrap_company(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION join_company(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION regenerate_invite_code() TO authenticated;
GRANT EXECUTE ON FUNCTION reserve_storage(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION release_storage(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION equipment_availability(uuid, timestamptz, timestamptz, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION allocate_kit(uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION align_allocations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION replace_kit_items(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION next_quote_number() TO authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE companies FORCE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles FORCE ROW LEVEL SECURITY;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'equipment_categories', 'equipment_items', 'kits', 'kit_items', 'consumables',
    'maintenance_logs', 'purchase_needs', 'clients', 'events', 'event_allocations',
    'quotes', 'quote_items', 'finance_categories', 'finance_transactions', 'stored_files'
  ]
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

CREATE POLICY companies_select ON companies
  FOR SELECT TO authenticated
  USING (id = current_company_id());

CREATE POLICY companies_update ON companies
  FOR UPDATE TO authenticated
  USING (id = current_company_id() AND has_role('admin'))
  WITH CHECK (id = current_company_id() AND has_role('admin'));

CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    OR auth_subject = current_jwt_sub()
  );

CREATE POLICY profiles_update ON profiles
  FOR UPDATE TO authenticated
  USING (
    company_id = current_company_id()
    AND (auth_subject = current_jwt_sub() OR has_role('admin'))
  )
  WITH CHECK (company_id = current_company_id());

-- Leitura operacional: qualquer membro ativo da empresa.
-- Financeiro fica restrito mais abaixo.

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'equipment_categories', 'equipment_items', 'kits', 'kit_items', 'consumables',
    'maintenance_logs', 'purchase_needs', 'clients', 'events', 'event_allocations',
    'quotes', 'quote_items', 'stored_files'
  ]
  LOOP
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (company_id = current_company_id())',
      t || '_select',
      t
    );
  END LOOP;
END $$;

CREATE POLICY finance_categories_select ON finance_categories
  FOR SELECT TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'financeiro'));

CREATE POLICY finance_transactions_select ON finance_transactions
  FOR SELECT TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'financeiro'));

-- Escrita de estoque
CREATE POLICY equipment_categories_write ON equipment_categories
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'));

CREATE POLICY equipment_items_insert ON equipment_items
  FOR INSERT TO authenticated
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'));

CREATE POLICY equipment_items_update ON equipment_items
  FOR UPDATE TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico'));

CREATE POLICY equipment_items_delete ON equipment_items
  FOR DELETE TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'));

CREATE POLICY kits_write ON kits
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'));

CREATE POLICY kit_items_write ON kit_items
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'));

CREATE POLICY consumables_write ON consumables
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque'));

CREATE POLICY maintenance_write ON maintenance_logs
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico'));

CREATE POLICY purchase_write ON purchase_needs
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico', 'comercial'));

CREATE POLICY stored_files_write ON stored_files
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'estoque', 'tecnico'));

-- Agenda, clientes e orçamentos
CREATE POLICY clients_write ON clients
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

CREATE POLICY events_write ON events
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

CREATE POLICY allocations_write ON event_allocations
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

CREATE POLICY quotes_write ON quotes
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

CREATE POLICY quote_items_write ON quote_items
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'comercial'));

CREATE POLICY finance_categories_write ON finance_categories
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'financeiro'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'financeiro'));

CREATE POLICY finance_transactions_write ON finance_transactions
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente', 'financeiro'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente', 'financeiro'));

NOTIFY pgrst, 'reload schema';

-- Opcional e exclusivo do Supabase Storage.
-- Não rode em Postgres comum: o schema storage não existe fora do Supabase.
-- Crie o bucket público "assets" e restrinja a escrita à pasta da empresa.
-- A URL pública usa um caminho com o uuid da empresa; a cota é controlada
-- pela função reserve_storage no schema public.

INSERT INTO storage.buckets (id, name, public)
VALUES ('assets', 'assets', true)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

DROP POLICY IF EXISTS assets_public_read ON storage.objects;
DROP POLICY IF EXISTS assets_insert ON storage.objects;
DROP POLICY IF EXISTS assets_update ON storage.objects;
DROP POLICY IF EXISTS assets_delete ON storage.objects;

CREATE POLICY assets_public_read ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'assets');

CREATE POLICY assets_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'assets'
    AND (storage.foldername(name))[1] = public.current_company_id()::text
  );

CREATE POLICY assets_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'assets'
    AND (storage.foldername(name))[1] = public.current_company_id()::text
  )
  WITH CHECK (
    bucket_id = 'assets'
    AND (storage.foldername(name))[1] = public.current_company_id()::text
  );

CREATE POLICY assets_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'assets'
    AND (storage.foldername(name))[1] = public.current_company_id()::text
  );

-- Primeiro administrador, chamado pelo SQL Editor (não pelo aplicativo).
-- O editor roda como postgres, sem JWT, então esta função recebe o UID
-- copiado de Authentication → Users. Ela não fica disponível para anon/authenticated.

CREATE OR REPLACE FUNCTION seed_first_admin(
  p_user_id text,
  p_email text,
  p_full_name text,
  p_company_name text,
  p_primary text DEFAULT '#0f6e6b',
  p_secondary text DEFAULT '#e8a838'
)
RETURNS TABLE (company_id uuid, slug text, invite_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user text := NULLIF(btrim(COALESCE(p_user_id, '')), '');
  v_company uuid;
  v_slug text;
  v_base text;
  v_code text;
  n integer := 0;
  tries integer := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Informe o UID do usuário criado em Authentication';
  END IF;
  IF to_regclass('auth.users') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE lower(id::text) = lower(v_user)) THEN
      RAISE EXCEPTION 'Não achei esse UID em Authentication. Copie a coluna UID do usuário.';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE auth_subject = v_user) THEN
    RAISE EXCEPTION 'Esse usuário já está ligado a uma empresa';
  END IF;
  IF p_company_name IS NULL OR char_length(btrim(p_company_name)) < 2 THEN
    RAISE EXCEPTION 'Informe o nome da empresa';
  END IF;
  IF p_full_name IS NULL OR char_length(btrim(p_full_name)) < 2 THEN
    RAISE EXCEPTION 'Informe o nome da pessoa';
  END IF;
  IF p_email IS NULL OR position('@' IN p_email) = 0 THEN
    RAISE EXCEPTION 'Informe o mesmo e-mail usado em Authentication';
  END IF;
  IF p_primary !~ '^#[0-9A-Fa-f]{6}$' OR p_secondary !~ '^#[0-9A-Fa-f]{6}$' THEN
    RAISE EXCEPTION 'Cores inválidas. Use o formato #112233';
  END IF;

  v_base := lower(btrim(p_company_name));
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
  WHILE EXISTS (SELECT 1 FROM companies AS c WHERE c.slug = v_slug) LOOP
    n := n + 1;
    v_slug := v_base || '-' || n::text;
  END LOOP;

  LOOP
    tries := tries + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM companies AS c WHERE c.invite_code = v_code);
    IF tries > 5 THEN
      RAISE EXCEPTION 'Não foi possível gerar um código de convite';
    END IF;
  END LOOP;

  PERFORM set_config('app.bypass_tenant', 'on', true);
  PERFORM set_config('app.allow_internal_company_update', 'on', true);

  INSERT INTO companies (name, slug, primary_color, secondary_color, invite_code)
  VALUES (btrim(p_company_name), v_slug, lower(p_primary), lower(p_secondary), v_code)
  RETURNING id INTO v_company;

  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'admin');

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

  company_id := v_company;
  slug := v_slug;
  invite_code := v_code;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION seed_first_admin(text, text, text, text, text, text) FROM PUBLIC;

DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role']
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format(
        'REVOKE ALL ON FUNCTION seed_first_admin(text, text, text, text, text, text) FROM %I',
        r
      );
    END IF;
  END LOOP;
END $$;

-- Palco — patch incremental de 22/10/2026
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez: só substitui a função next_quote_number.
--
-- Motivo: o número seguinte era count(*) + 1. Depois de excluir um rascunho
-- que não era o último, o próximo orçamento repetia um número que ainda existia
-- e o salvamento falhava.

CREATE OR REPLACE FUNCTION next_quote_number()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company uuid := current_company_id();
  v_n integer;
BEGIN
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  SELECT COALESCE(MAX(
    CASE
      WHEN number ~ '^ORC-[0-9]+$' THEN substring(number FROM 5)::integer
      ELSE NULL
    END
  ), 0) + 1
  INTO v_n
  FROM quotes
  WHERE company_id = v_company;
  RETURN 'ORC-' || lpad(v_n::text, 4, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION next_quote_number() TO authenticated;

NOTIFY pgrst, 'reload schema';

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

-- Palco — patch incremental (22/10/2026, ordem de serviço e status)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez.
--
-- Inclui: telefone do técnico no evento, motorista do transporte
-- e o status "cancelado" no orçamento.

ALTER TABLE event_freelancers ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE event_transports ADD COLUMN IF NOT EXISTS driver_name text;

ALTER TABLE quotes DROP CONSTRAINT IF EXISTS quotes_status_check;
ALTER TABLE quotes ADD CONSTRAINT quotes_status_check
  CHECK (status IN ('rascunho', 'enviado', 'aprovado', 'recusado', 'cancelado'));

NOTIFY pgrst, 'reload schema';

-- Palco — patch incremental (22/10/2026, desconto percentual)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez. Não apaga dado, não recria tabela e não mexe em política.
--
-- Inclui: desconto em porcentagem no orçamento, além do desconto fixo em reais.
-- A política quotes_write segue valendo (linha da empresa, papéis admin, gerente e comercial).
-- O GRANT da tabela quotes já cobre a coluna nova. Não há GRANT extra.

ALTER TABLE quotes ADD COLUMN IF NOT EXISTS discount_percent numeric(5, 2) NOT NULL DEFAULT 0;

ALTER TABLE quotes DROP CONSTRAINT IF EXISTS quotes_discount_percent_check;
ALTER TABLE quotes ADD CONSTRAINT quotes_discount_percent_check
  CHECK (discount_percent >= 0 AND discount_percent <= 100);

NOTIFY pgrst, 'reload schema';

-- Palco — patch de equipe e freelancer (22/10/2026)
-- Cole este arquivo no SQL Editor e execute. Não rode palco_supabase.sql de novo.
-- Pode rodar mais de uma vez. Não apaga tabela, não trunca e não dá DELETE sem filtro.
--
-- O cargo visualizador passa a se chamar freelancer.
-- O administrador remove um membro pela função remove_company_member
-- (não apaga o usuário do Auth: isso exigiria a service role, que não fica no app).
-- O nome já gravado no evento e na OS permanece.
-- Convite de freelancer é outro código, sem senha. Bloqueio, revogação e validade
-- são checados em toda leitura.

SELECT set_config('app.bypass_tenant', 'on', false);

-- ---------------------------------------------------------------------------
-- Papel
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
      AND pg_get_constraintdef(con.oid) ILIKE '%visualizador%'
  LOOP
    EXECUTE format('ALTER TABLE profiles DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
UPDATE profiles SET role = 'freelancer' WHERE role = 'visualizador';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_role_check'
  ) THEN
    ALTER TABLE profiles
      ADD CONSTRAINT profiles_role_check
      CHECK (role IN (
        'admin', 'gerente', 'financeiro', 'estoque', 'tecnico', 'comercial', 'freelancer'
      ));
  END IF;
END $$;

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS freelancer_id uuid REFERENCES freelancers (id) ON DELETE SET NULL;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'role_price_visibility'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%visualizador%'
  LOOP
    EXECUTE format('ALTER TABLE role_price_visibility DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE role_price_visibility DROP CONSTRAINT IF EXISTS role_price_visibility_role_check;
UPDATE role_price_visibility
SET role = 'freelancer'
WHERE role = 'visualizador'
  AND NOT EXISTS (
    SELECT 1 FROM role_price_visibility other
    WHERE other.company_id = role_price_visibility.company_id
      AND other.role = 'freelancer'
  );
DELETE FROM role_price_visibility WHERE role = 'visualizador';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'role_price_visibility_role_check'
  ) THEN
    ALTER TABLE role_price_visibility
      ADD CONSTRAINT role_price_visibility_role_check
      CHECK (role IN (
        'admin', 'gerente', 'financeiro', 'estoque', 'tecnico', 'comercial', 'freelancer'
      ));
  END IF;
END $$;

INSERT INTO role_price_visibility (company_id, role, can_see_prices)
SELECT id, 'freelancer', false FROM companies
ON CONFLICT (company_id, role) DO UPDATE SET can_see_prices = false;

CREATE OR REPLACE FUNCTION lock_freelancer_price_flag()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.role = 'freelancer' AND NEW.can_see_prices THEN
    RAISE EXCEPTION 'Freelancer não vê valores';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_freelancer_price ON role_price_visibility;
CREATE TRIGGER trg_lock_freelancer_price
  BEFORE INSERT OR UPDATE ON role_price_visibility
  FOR EACH ROW EXECUTE FUNCTION lock_freelancer_price_flag();

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
  SELECT id INTO v_company
  FROM companies
  WHERE invite_code = upper(btrim(COALESCE(p_code, '')));
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Código de convite inválido';
  END IF;
  INSERT INTO profiles (auth_subject, company_id, full_name, email, role)
  VALUES (v_user, v_company, btrim(p_full_name), lower(btrim(p_email)), 'freelancer');
  RETURN v_company;
END;
$$;

-- ---------------------------------------------------------------------------
-- Convites de acesso sem senha
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS freelancer_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
  freelancer_id uuid NOT NULL REFERENCES freelancers (id) ON DELETE CASCADE,
  code text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9]{6,16}$'),
  expires_at timestamptz,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'blocked', 'revoked')),
  auth_subject text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS freelancer_invites_company_idx
  ON freelancer_invites (company_id, status);
CREATE INDEX IF NOT EXISTS freelancer_invites_freelancer_idx
  ON freelancer_invites (freelancer_id);

ALTER TABLE freelancer_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE freelancer_invites FORCE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_00_tenant ON freelancer_invites;
CREATE TRIGGER trg_00_tenant
  BEFORE INSERT OR UPDATE ON freelancer_invites
  FOR EACH ROW EXECUTE FUNCTION set_tenant_company();

DROP TRIGGER IF EXISTS trg_90_touch ON freelancer_invites;
CREATE TRIGGER trg_90_touch
  BEFORE UPDATE ON freelancer_invites
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION freelancer_session_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN current_app_role() IS DISTINCT FROM 'freelancer' THEN true
    WHEN NOT EXISTS (
      SELECT 1 FROM freelancer_invites WHERE auth_subject = current_jwt_sub()
    ) THEN true
    ELSE EXISTS (
      SELECT 1 FROM freelancer_invites i
      WHERE i.auth_subject = current_jwt_sub()
        AND i.status = 'active'
        AND (i.expires_at IS NULL OR i.expires_at > now())
    )
  END;
$$;

CREATE OR REPLACE FUNCTION freelancer_on_event(p_event uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM event_freelancers ef
    JOIN profiles p
      ON p.auth_subject = current_jwt_sub()
     AND p.active
     AND p.company_id = ef.company_id
    WHERE ef.event_id = p_event
      AND (
        (p.freelancer_id IS NOT NULL AND ef.freelancer_id = p.freelancer_id)
        OR (
          p.freelancer_id IS NULL
          AND lower(btrim(ef.name)) = lower(btrim(p.full_name))
        )
      )
  );
$$;

CREATE OR REPLACE FUNCTION freelancer_access_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT freelancer_session_ok();
$$;

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
  v_admins integer;
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
    SELECT count(*) INTO v_admins
    FROM profiles
    WHERE company_id = v_company
      AND role = 'admin'
      AND active;
    IF v_admins <= 1 THEN
      RAISE EXCEPTION 'A empresa precisa manter um administrador';
    END IF;
  END IF;

  UPDATE freelancer_invites
  SET status = 'revoked', updated_at = now()
  WHERE company_id = v_company
    AND auth_subject = v_target_subject
    AND status <> 'revoked';

  DELETE FROM profiles WHERE id = p_profile_id AND company_id = v_company;
END;
$$;

CREATE OR REPLACE FUNCTION create_freelancer_invite(
  p_freelancer_id uuid,
  p_expires_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid;
  v_code text;
  v_id uuid;
  v_try integer := 0;
BEGIN
  IF NOT has_role('admin', 'gerente') THEN
    RAISE EXCEPTION 'Apenas administrador ou gerente gera convite';
  END IF;
  v_company := current_company_id();
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'Sem empresa vinculada à sessão';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM freelancers WHERE id = p_freelancer_id AND company_id = v_company
  ) THEN
    RAISE EXCEPTION 'Freelancer de outra empresa';
  END IF;

  UPDATE freelancer_invites
  SET status = 'revoked', updated_at = now()
  WHERE freelancer_id = p_freelancer_id
    AND company_id = v_company
    AND status = 'active';

  LOOP
    v_try := v_try + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM freelancer_invites WHERE code = v_code);
    IF v_try > 8 THEN
      RAISE EXCEPTION 'Não foi possível gerar o código';
    END IF;
  END LOOP;

  INSERT INTO freelancer_invites (company_id, freelancer_id, code, expires_at, status)
  VALUES (v_company, p_freelancer_id, v_code, p_expires_at, 'active')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'code', v_code,
    'freelancer_id', p_freelancer_id,
    'expires_at', p_expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION set_freelancer_invite_status(
  p_invite_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company uuid := current_company_id();
BEGIN
  IF p_status NOT IN ('active', 'blocked', 'revoked') THEN
    RAISE EXCEPTION 'Status inválido';
  END IF;
  IF NOT has_role('admin', 'gerente') THEN
    RAISE EXCEPTION 'Apenas administrador ou gerente altera o convite';
  END IF;
  UPDATE freelancer_invites
  SET status = p_status, updated_at = now()
  WHERE id = p_invite_id
    AND company_id = v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Convite não encontrado';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION redeem_freelancer_invite(p_code text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user text := current_jwt_sub();
  v_invite freelancer_invites%ROWTYPE;
  v_name text;
  v_email text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Sessão inválida';
  END IF;

  SELECT * INTO v_invite
  FROM freelancer_invites
  WHERE code = upper(btrim(COALESCE(p_code, '')));

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código inválido';
  END IF;
  IF v_invite.status = 'blocked' THEN
    RAISE EXCEPTION 'Este acesso está bloqueado';
  END IF;
  IF v_invite.status = 'revoked' THEN
    RAISE EXCEPTION 'Este acesso foi revogado';
  END IF;
  IF v_invite.expires_at IS NOT NULL AND v_invite.expires_at <= now() THEN
    RAISE EXCEPTION 'Este acesso expirou';
  END IF;
  IF EXISTS (
    SELECT 1 FROM profiles
    WHERE auth_subject = v_user
      AND company_id IS DISTINCT FROM v_invite.company_id
  ) THEN
    RAISE EXCEPTION 'Esta sessão já está em outra empresa';
  END IF;

  SELECT name INTO v_name FROM freelancers WHERE id = v_invite.freelancer_id;
  v_email := 'f.' || lower(v_invite.code) || '@convite.palco.app';

  IF v_invite.auth_subject IS NOT NULL AND v_invite.auth_subject IS DISTINCT FROM v_user THEN
    DELETE FROM profiles
    WHERE auth_subject = v_invite.auth_subject
      AND company_id = v_invite.company_id
      AND role = 'freelancer';
  END IF;

  INSERT INTO profiles (auth_subject, company_id, full_name, email, role, active, freelancer_id)
  VALUES (
    v_user,
    v_invite.company_id,
    COALESCE(NULLIF(btrim(v_name), ''), 'Freelancer'),
    v_email,
    'freelancer',
    true,
    v_invite.freelancer_id
  )
  ON CONFLICT (auth_subject) DO UPDATE
    SET full_name = EXCLUDED.full_name,
        email = EXCLUDED.email,
        role = 'freelancer',
        active = true,
        freelancer_id = EXCLUDED.freelancer_id;

  UPDATE freelancer_invites
  SET auth_subject = v_user, updated_at = now()
  WHERE id = v_invite.id;
END;
$$;

-- ---------------------------------------------------------------------------
-- RLS: freelancer só lê a própria agenda
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS profiles_select ON profiles;
CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (
    auth_subject = current_jwt_sub()
    OR (
      company_id = current_company_id()
      AND current_app_role() IS DISTINCT FROM 'freelancer'
    )
  );

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'equipment_categories', 'kits', 'kit_items', 'consumables',
    'maintenance_logs', 'purchase_needs', 'clients', 'quotes', 'quote_items',
    'stored_files', 'freelancers', 'vehicles', 'vehicle_maintenance',
    'role_price_visibility'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_select', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (company_id = current_company_id() AND current_app_role() IS DISTINCT FROM ''freelancer'')',
      t || '_select',
      t
    );
  END LOOP;
END $$;

DROP POLICY IF EXISTS events_select ON events;
CREATE POLICY events_select ON events
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(id))
    )
  );

DROP POLICY IF EXISTS event_allocations_select ON event_allocations;
CREATE POLICY event_allocations_select ON event_allocations
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(event_id))
    )
  );

DROP POLICY IF EXISTS event_freelancers_select ON event_freelancers;
CREATE POLICY event_freelancers_select ON event_freelancers
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(event_id))
    )
  );

DROP POLICY IF EXISTS event_transports_select ON event_transports;
CREATE POLICY event_transports_select ON event_transports
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR (freelancer_session_ok() AND freelancer_on_event(event_id))
    )
  );

DROP POLICY IF EXISTS equipment_items_select ON equipment_items;
CREATE POLICY equipment_items_select ON equipment_items
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND (
      current_app_role() IS DISTINCT FROM 'freelancer'
      OR EXISTS (
        SELECT 1 FROM event_allocations a
        WHERE a.equipment_item_id = equipment_items.id
          AND freelancer_on_event(a.event_id)
          AND freelancer_session_ok()
      )
    )
  );

DROP POLICY IF EXISTS freelancer_invites_select ON freelancer_invites;
CREATE POLICY freelancer_invites_select ON freelancer_invites
  FOR SELECT TO authenticated
  USING (
    company_id = current_company_id()
    AND has_role('admin', 'gerente')
  );

DROP POLICY IF EXISTS freelancer_invites_write ON freelancer_invites;
CREATE POLICY freelancer_invites_write ON freelancer_invites
  FOR ALL TO authenticated
  USING (company_id = current_company_id() AND has_role('admin', 'gerente'))
  WITH CHECK (company_id = current_company_id() AND has_role('admin', 'gerente'));

-- Valores mascarados na leitura usada pelo app. A policy acima já esconde
-- orçamento, financeiro e o catálogo. Diária e combustível do próprio evento
-- saem nulos para o papel freelancer.
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
  END AS daily_rate
FROM event_freelancers;

CREATE OR REPLACE VIEW event_trips_visible
WITH (security_invoker = true) AS
SELECT
  id,
  company_id,
  event_id,
  vehicle_id,
  plate,
  model,
  driver_name,
  distance_km,
  consumption_km_per_liter,
  notes,
  created_at,
  CASE WHEN current_app_role() = 'freelancer' THEN NULL ELSE fuel_price END AS fuel_price,
  CASE WHEN current_app_role() = 'freelancer' THEN NULL ELSE tolls END AS tolls,
  CASE WHEN current_app_role() = 'freelancer' THEN NULL ELSE other_cost END AS other_cost
FROM event_transports;

CREATE OR REPLACE VIEW freelancer_invite_gaps
WITH (security_invoker = true) AS
SELECT DISTINCT
  f.company_id,
  f.id AS freelancer_id,
  f.name AS freelancer_name,
  e.id AS event_id,
  e.title AS event_title
FROM event_freelancers ef
JOIN freelancers f ON f.id = ef.freelancer_id
JOIN events e ON e.id = ef.event_id
WHERE e.status NOT IN ('concluido', 'cancelado')
  AND NOT EXISTS (
    SELECT 1 FROM freelancer_invites i
    WHERE i.freelancer_id = f.id
      AND i.status = 'active'
      AND (i.expires_at IS NULL OR i.expires_at > now())
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON freelancer_invites TO authenticated;
GRANT SELECT ON event_crew_visible, event_trips_visible, freelancer_invite_gaps TO authenticated;

GRANT EXECUTE ON FUNCTION freelancer_session_ok() TO authenticated;
GRANT EXECUTE ON FUNCTION freelancer_on_event(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION freelancer_access_open() TO authenticated;
GRANT EXECUTE ON FUNCTION remove_company_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION create_freelancer_invite(uuid, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION set_freelancer_invite_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION redeem_freelancer_invite(text) TO authenticated;
GRANT EXECUTE ON FUNCTION join_company(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION lock_freelancer_price_flag() TO authenticated;

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

