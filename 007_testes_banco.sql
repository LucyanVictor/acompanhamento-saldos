-- ============================================================
-- Testes automáticos do banco (regras que NÃO dependem da tela)
-- Como usar: SQL Editor > cole tudo > Run.
-- Tudo roda dentro de uma única transação que termina de propósito com um erro,
-- o que desfaz todos os dados de teste. Seus dados reais não são tocados.
--   Resultado esperado:  "TESTES CONCLUÍDOS: todos passaram ..."  (aparece como mensagem de erro)
--   Se algum teste falhar, a mensagem começa com "FALHOU:" e diz qual regra quebrou.
-- Observação: este script usa o CNPJ de teste 11.444.777/0001-61. Se você tiver cadastrado uma empresa
-- com esse CNPJ, o teste para antes de começar (mensagem de CNPJ duplicado). Nesse caso, use outro CNPJ válido.
-- ============================================================
do $$
declare cid uuid; cat uuid; aid uuid; pid uuid; rid uuid; ok boolean; n int; d numeric;
begin
  -- 1. CNPJ: dígitos verificadores
  if not cnpj_valid('11.444.777/0001-61') then raise exception 'FALHOU: CNPJ válido foi recusado'; end if;
  if cnpj_valid('11.444.777/0001-62') or cnpj_valid('11111111111111') or cnpj_valid('') then
    raise exception 'FALHOU: CNPJ inválido foi aceito'; end if;

  -- preparação
  insert into companies (legal_name, cnpj) values ('ZZ TESTE AUTOMATICO', '11444777000161') returning id into cid;
  insert into account_categories (company_id, kind, name, counts_as_cash) values (cid, 'bank', 'Teste', true) returning id into cat;
  insert into monitored_accounts (company_id, category_id, description, account_number, accounting_code)
    values (cid, cat, 'Conta A', '00123-4', '007') returning id into aid;

  -- 2. Número de conta preserva zeros e hífen (texto)
  if (select account_number from monitored_accounts where id = aid) <> '00123-4' then raise exception 'FALHOU: número da conta não foi preservado como texto'; end if;

  insert into monthly_periods (company_id, year, month) values (cid, 2099, 1) returning id into pid;
  insert into monthly_account_records (period_id, account_id) values (pid, aid) returning id into rid;

  -- 3. Saldo vazio é diferente de saldo zero
  if (select final_balance from monthly_account_records where id = rid) is not null then raise exception 'FALHOU: saldo novo deveria ser vazio (NULL)'; end if;
  update monthly_account_records set final_balance = 0 where id = rid;
  if (select final_balance from monthly_account_records where id = rid) is null then raise exception 'FALHOU: saldo zero foi tratado como vazio'; end if;

  -- 4. Sem duplicidade de competência e de registro
  ok := false; begin insert into monthly_periods (company_id, year, month) values (cid, 2099, 1); exception when unique_violation then ok := true; end;
  if not ok then raise exception 'FALHOU: competência duplicada foi aceita'; end if;
  ok := false; begin insert into monthly_account_records (period_id, account_id) values (pid, aid); exception when unique_violation then ok := true; end;
  if not ok then raise exception 'FALHOU: registro duplicado (mesma conta e competência) foi aceito'; end if;

  -- 5. CNPJ inválido barrado no banco
  ok := false; begin insert into companies (legal_name, cnpj) values ('X', '11444777000162'); exception when check_violation then ok := true; end;
  if not ok then raise exception 'FALHOU: empresa com CNPJ inválido foi aceita'; end if;

  -- 6. Auditoria registra a alteração de saldo
  update monthly_account_records set final_balance = 1234.56, status = 'concluido' where id = rid;
  select count(*) into n from audit_logs where record_id = rid and field = 'final_balance' and new_value = '1234.56';
  if n <> 1 then raise exception 'FALHOU: auditoria não registrou a alteração de saldo (encontrou % linha(s))', n; end if;

  -- 7. Divergência: diferença calculada, sem exclusão, resolvida exige data
  insert into reconciliation_issues (record_id, description, reference_value, found_value) values (rid, 'teste', 1000, 950);
  select difference into d from reconciliation_issues where record_id = rid;
  if d is distinct from -50 then raise exception 'FALHOU: diferença deveria ser -50 e foi %', d; end if;
  ok := false; begin delete from reconciliation_issues where record_id = rid; exception when others then ok := true; end;
  if not ok then raise exception 'FALHOU: divergência foi excluída (deveria ser preservada)'; end if;
  ok := false; begin update reconciliation_issues set resolved = true where record_id = rid; exception when check_violation then ok := true; end;
  if not ok then raise exception 'FALHOU: divergência resolvida sem data foi aceita'; end if;

  -- 8. A situação da competência não muda por UPDATE direto
  ok := false; begin update monthly_periods set status = 'encerrada' where id = pid; exception when others then ok := true; end;
  if not ok then raise exception 'FALHOU: situação da competência foi alterada sem passar pela função de encerramento'; end if;

  -- 9. Competência encerrada bloqueia alterações (encerramento simulado pelo mesmo caminho das funções)
  perform set_config('app.period_op', '1', true);
  update monthly_periods set status = 'encerrada', closed_at = now() where id = pid;
  perform set_config('app.period_op', '', true);
  ok := false; begin update monthly_account_records set final_balance = 5 where id = rid; exception when others then ok := true; end;
  if not ok then raise exception 'FALHOU: registro foi alterado em competência encerrada'; end if;
  ok := false; begin insert into reconciliation_issues (record_id, description) values (rid, 'x'); exception when others then ok := true; end;
  if not ok then raise exception 'FALHOU: divergência foi criada em competência encerrada'; end if;

  -- 10. Segurança: RLS ligada, sem acesso anônimo, auditoria protegida
  select count(*) into n from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
    and relname in ('profiles','companies','company_members','account_categories','monitored_accounts','monthly_periods','monthly_account_records','reconciliation_issues','audit_logs');
  if n <> 9 then raise exception 'FALHOU: RLS ligada em % de 9 tabelas', n; end if;
  if has_table_privilege('anon','companies','select') or has_table_privilege('anon','monthly_account_records','select') or has_table_privilege('anon','audit_logs','select') then
    raise exception 'FALHOU: usuário anônimo tem acesso a tabelas financeiras'; end if;
  if has_table_privilege('authenticated','audit_logs','insert') or has_table_privilege('authenticated','audit_logs','update') or has_table_privilege('authenticated','audit_logs','delete') then
    raise exception 'FALHOU: usuários comuns podem alterar o histórico de auditoria'; end if;

  raise exception 'TESTES CONCLUÍDOS: todos passaram. Os dados de teste foram desfeitos automaticamente (esta mensagem de erro é esperada).';
end $$;
