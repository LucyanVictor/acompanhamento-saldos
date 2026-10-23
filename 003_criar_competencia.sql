-- ============================================================
-- Função que cria uma competência com os registros das contas ativas,
--    de forma atômica (tudo ou nada). Usada pelo botão "Criar competência".
--    Saldo final fica vazio, situação Pendente, saldo anterior vem do mês anterior.
-- ============================================================
create or replace function create_period(p_company uuid, p_year int, p_month int) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid; py int; pm int; prev uuid;
begin
  if not has_company_access(p_company) or coalesce(current_role_app()::text,'') not in ('admin','supervisor') then
    raise exception 'Sem permissão para criar competências nesta empresa.';
  end if;
  insert into monthly_periods (company_id, year, month) values (p_company, p_year, p_month) returning id into pid;

  py := case when p_month = 1 then p_year - 1 else p_year end;
  pm := case when p_month = 1 then 12 else p_month - 1 end;
  select id into prev from monthly_periods where company_id = p_company and year = py and month = pm;

  insert into monthly_account_records (period_id, account_id, previous_balance, responsible_id)
  select pid, a.id,
         (select r.final_balance from monthly_account_records r where r.period_id = prev and r.account_id = a.id),
         a.default_responsible
  from monitored_accounts a join account_categories c on c.id = a.category_id
  where a.company_id = p_company and a.active and c.active;
  return pid;
end $$;

revoke execute on function create_period(uuid, int, int) from public, anon;
grant  execute on function create_period(uuid, int, int) to authenticated;
