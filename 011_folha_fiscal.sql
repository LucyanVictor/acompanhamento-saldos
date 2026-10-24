-- ============================================================
-- Novos grupos "Folha" (módulos CLT e Ministros) e "Fiscal"
-- Rode UMA vez no SQL Editor (pode rodar de novo sem problema) e depois rode de novo o 006_importacao.sql
-- (atualizado: só categorias de banco e caixa entram na disponibilidade financeira).
-- ============================================================
alter type group_kind add value if not exists 'payroll';
alter type group_kind add value if not exists 'fiscal';
