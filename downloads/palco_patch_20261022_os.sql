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
