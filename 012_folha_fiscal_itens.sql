-- ============================================================
-- Folha e Fiscal simplificados: adicionar / editar / remover item direto na tela.
-- Rode DEPOIS do 011_folha_fiscal.sql. Todos os perfis ativos com acesso à empresa podem usar
-- (a competência precisa estar aberta). Tudo é atômico e fica na auditoria.
-- ============================================================

-- Adiciona um item (cria a categoria do módulo se não existir, a conta e o registro do mês)
create or replace function add_ff_item(p_period uuid, p_kind group_kind, p_category text, p_description text,
                                       p_code text, p_status record_status, p_resp uuid, p_balance numeric)
returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid; pst period_status; cat uuid; aid uuid; rid uuid;
begin
  if p_kind not in ('payroll','fiscal') then raise exception 'Tipo de item inválido.'; end if;
  select company_id, status into cid, pst from monthly_periods where id = p_period;
  if cid is null then raise exception 'Competência não encontrada.'; end if;
  if current_role_app() is null or not has_company_access(cid) then raise exception 'Sem permissão para esta empresa.'; end if;
  if pst = 'encerrada' then raise exception 'Competência encerrada: alterações bloqueadas.'; end if;
  if length(trim(coalesce(p_description, ''))) = 0 then raise exception 'Informe a descrição.'; end if;

  select id into cat from account_categories where company_id = cid and kind = p_kind and lower(name) = lower(trim(p_category));
  if cat is null then
    insert into account_categories (company_id, kind, name, counts_as_cash, sort_order)
    values (cid, p_kind, trim(p_category), false,
            coalesce((select max(sort_order) from account_categories where company_id = cid and kind = p_kind), 0) + 1)
    returning id into cat;
  else
    update account_categories set active = true where id = cat and not active;
  end if;

  if exists (select 1 from monitored_accounts where category_id = cat and active and lower(trim(description)) = lower(trim(p_description))) then
    raise exception 'Já existe um item com essa descrição neste módulo.';
  end if;

  insert into monitored_accounts (company_id, category_id, description, accounting_code, default_responsible, sort_order)
  values (cid, cat, trim(p_description), nullif(trim(p_code), ''), p_resp,
          coalesce((select max(sort_order) from monitored_accounts where company_id = cid and category_id = cat), 0) + 1)
  returning id into aid;

  insert into monthly_account_records (period_id, account_id, final_balance, status, responsible_id)
  values (p_period, aid, p_balance, coalesce(p_status, 'pendente'), p_resp) returning id into rid;
  return rid;
end $$;

-- Corrige descrição e código contábil do item (competência aberta)
create or replace function update_ff_item(p_record uuid, p_description text, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare r monthly_account_records%rowtype; cid uuid; pst period_status; a monitored_accounts%rowtype; k group_kind;
begin
  select * into r from monthly_account_records where id = p_record;
  if not found then raise exception 'Item não encontrado.'; end if;
  select company_id, status into cid, pst from monthly_periods where id = r.period_id;
  if current_role_app() is null or not has_company_access(cid) then raise exception 'Sem permissão para esta empresa.'; end if;
  if pst = 'encerrada' then raise exception 'Competência encerrada: alterações bloqueadas.'; end if;
  select * into a from monitored_accounts where id = r.account_id;
  select kind into k from account_categories where id = a.category_id;
  if k not in ('payroll','fiscal') then raise exception 'Este item não pode ser editado aqui.'; end if;
  if length(trim(coalesce(p_description, ''))) = 0 then raise exception 'Informe a descrição.'; end if;
  if exists (select 1 from monitored_accounts where category_id = a.category_id and id <> a.id and active
              and lower(trim(description)) = lower(trim(p_description))) then
    raise exception 'Já existe um item com essa descrição neste módulo.';
  end if;
  update monitored_accounts set description = trim(p_description), accounting_code = nullif(trim(p_code), '') where id = a.id;
end $$;

-- Remove o item: não entra mais nos próximos meses. Se o registro deste mês está vazio, ele some também;
-- se já tem dados (ou divergência), fica neste mês para preservar o histórico.
create or replace function remove_ff_item(p_record uuid) returns text
language plpgsql security definer set search_path = public as $$
declare r monthly_account_records%rowtype; cid uuid; pst period_status; a monitored_accounts%rowtype; k group_kind;
begin
  select * into r from monthly_account_records where id = p_record;
  if not found then raise exception 'Item não encontrado.'; end if;
  select company_id, status into cid, pst from monthly_periods where id = r.period_id;
  if current_role_app() is null or not has_company_access(cid) then raise exception 'Sem permissão para esta empresa.'; end if;
  if pst = 'encerrada' then raise exception 'Competência encerrada: alterações bloqueadas.'; end if;
  select * into a from monitored_accounts where id = r.account_id;
  select kind into k from account_categories where id = a.category_id;
  if k not in ('payroll','fiscal') then raise exception 'Este item não pode ser removido aqui.'; end if;

  update monitored_accounts set active = false where id = a.id;
  if r.final_balance is null and r.status = 'pendente' and not exists (select 1 from reconciliation_issues where record_id = r.id) then
    delete from monthly_account_records where id = r.id;
    return 'removed';
  end if;
  return 'kept';
end $$;

revoke execute on function add_ff_item(uuid, group_kind, text, text, text, record_status, uuid, numeric),
                          update_ff_item(uuid, text, text), remove_ff_item(uuid) from public, anon;
grant  execute on function add_ff_item(uuid, group_kind, text, text, text, record_status, uuid, numeric),
                          update_ff_item(uuid, text, text), remove_ff_item(uuid) to authenticated;
