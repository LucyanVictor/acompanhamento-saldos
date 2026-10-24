-- ============================================================
-- Etapa 5.1 — Importação de planilha (CSV/XLSX) de forma atômica
-- Recebe as linhas já validadas pela tela. Tudo ou nada: se qualquer linha falhar, nada é gravado.
-- Registros que já têm dados só são alterados se p_overwrite = true (escolha explícita na tela).
-- ============================================================
create or replace function import_period_rows(p_company uuid, p_year int, p_month int, p_rows jsonb, p_overwrite boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid uuid; pst period_status; x jsonb; k group_kind; cat uuid; aid uuid; ex monthly_account_records%rowtype;
  rb numeric; rs record_status; resp uuid;
  n_acc int := 0; n_fill int := 0; n_upd int := 0; n_keep int := 0;
begin
  if not has_company_access(p_company) or coalesce(current_role_app()::text, '') not in ('admin','supervisor') then
    raise exception 'Sem permissão para importar nesta empresa.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Nenhuma linha para importar.'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'Limite de 2000 linhas por importação.'; end if;

  select id, status into pid, pst from monthly_periods where company_id = p_company and year = p_year and month = p_month;
  if pid is null then
    pid := create_period(p_company, p_year, p_month);      -- abre a competência copiando as contas ativas como pendentes
  elsif pst = 'encerrada' then
    raise exception 'A competência está encerrada.';
  end if;

  for x in select value from jsonb_array_elements(p_rows) loop
    k := (x->>'kind')::group_kind;
    if length(trim(coalesce(x->>'description',''))) = 0 then raise exception 'Linha sem descrição.'; end if;

    select id into cat from account_categories
     where company_id = p_company and kind = k and lower(name) = lower(trim(x->>'category'));
    if cat is null then
      insert into account_categories (company_id, kind, name, counts_as_cash, sort_order)
      values (p_company, k, trim(x->>'category'), k not in ('third_party','card'),
              coalesce((select max(sort_order) from account_categories where company_id = p_company and kind = k), 0) + 1)
      returning id into cat;
    end if;

    select a.id into aid from monitored_accounts a join account_categories c on c.id = a.category_id
     where a.company_id = p_company and c.kind = k
       and lower(trim(a.description)) = lower(trim(x->>'description'))
       and coalesce(trim(a.account_number), '') = coalesce(trim(x->>'account_number'), '')
     limit 1;
    if aid is null then
      insert into monitored_accounts (company_id, category_id, description, institution, account_number, accounting_code, sort_order)
      values (p_company, cat, trim(x->>'description'), nullif(trim(x->>'institution'), ''), nullif(trim(x->>'account_number'), ''),
              nullif(trim(x->>'accounting_code'), ''),
              coalesce((select max(sort_order) from monitored_accounts where company_id = p_company and category_id = cat), 0) + 1)
      returning id into aid;
      n_acc := n_acc + 1;
    end if;

    rb := nullif(x->>'final_balance', '')::numeric;
    rs := (x->>'status')::record_status;
    resp := nullif(x->>'responsible_id', '')::uuid;

    select * into ex from monthly_account_records where period_id = pid and account_id = aid;
    if not found then
      insert into monthly_account_records (period_id, account_id, final_balance, status, responsible_id)
      values (pid, aid, rb, rs, resp);
      n_fill := n_fill + 1;
    elsif ex.final_balance is null and ex.status = 'pendente' then
      update monthly_account_records set final_balance = rb, status = rs, responsible_id = coalesce(resp, ex.responsible_id) where id = ex.id;
      n_fill := n_fill + 1;
    elsif p_overwrite then
      update monthly_account_records set final_balance = rb, status = rs, responsible_id = coalesce(resp, ex.responsible_id) where id = ex.id;
      n_upd := n_upd + 1;
    else
      n_keep := n_keep + 1;
    end if;
  end loop;

  return jsonb_build_object('period_id', pid, 'accounts_created', n_acc, 'records_filled', n_fill,
                            'records_overwritten', n_upd, 'records_kept', n_keep);
end $$;

revoke execute on function import_period_rows(uuid, int, int, jsonb, boolean) from public, anon;
grant  execute on function import_period_rows(uuid, int, int, jsonb, boolean) to authenticated;
