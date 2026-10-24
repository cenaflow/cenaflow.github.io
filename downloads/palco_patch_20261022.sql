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
