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
