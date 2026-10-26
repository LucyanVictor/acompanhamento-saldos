-- ============================================================
-- Declaração de Faturamento: observações com histórico
-- Rode UMA vez no SQL Editor, DEPOIS do 017 e do 018 (pode rodar de novo sem problema).
--  * notes: observação atual (salva automaticamente, uso interno, não sai no PDF).
--  * notes_history: últimas 10 observações usadas em PDFs emitidos, para reaproveitar.
-- ============================================================
alter table billing_settings add column if not exists notes text;
alter table billing_settings add column if not exists notes_history jsonb not null default '[]'::jsonb;
alter table billing_settings drop constraint if exists billing_settings_notes_check;
alter table billing_settings add constraint billing_settings_notes_check
  check ((notes is null or length(notes) <= 2000)
     and jsonb_typeof(notes_history) = 'array' and jsonb_array_length(notes_history) <= 10
     and pg_column_size(notes_history) <= 30000);
