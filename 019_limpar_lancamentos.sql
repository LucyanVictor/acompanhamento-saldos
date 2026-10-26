-- ============================================================
-- LIMPEZA DOS LANÇAMENTOS DE TESTE  (NÃO TEM COMO DESFAZER)
-- Apaga: todas as competências (meses), saldos, situações, responsáveis e observações
--        lançados no Acompanhamento mensal, Cartões, Folha, Fiscal e Apropriação;
--        divergências; valores digitados na Declaração de Faturamento; histórico de auditoria.
-- Mantém: usuários e logins, empresas, vínculos, categorias, contas, cartões, maquininhas,
--         itens cadastrados de Folha/Fiscal/Apropriação, assinantes e logotipos da Declaração.
-- Como usar: SQL Editor > cole tudo > Run. Rode uma vez só.
-- ============================================================
begin;

-- Mostra o que será apagado (aparece no resultado)
select 'competências' as item, count(*) as quantidade from monthly_periods
union all select 'lançamentos mensais', count(*) from monthly_account_records
union all select 'divergências', count(*) from reconciliation_issues
union all select 'valores da declaração', count(*) from billing_month_values
union all select 'registros de auditoria', count(*) from audit_logs;

-- TRUNCATE apaga tudo de uma vez, inclusive de meses encerrados, sem gerar novo histórico
truncate table reconciliation_issues, monthly_account_records, monthly_periods, billing_month_values, audit_logs restart identity;

commit;
