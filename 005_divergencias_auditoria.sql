-- ============================================================
-- Etapa 3.2 — Divergências protegidas e auditoria completa
-- ============================================================

-- Resolvida <=> tem data de resolução
alter table reconciliation_issues
  add constraint chk_issue_resolved check (resolved = (resolved_at is not null));

-- Divergências: bloqueadas em competência encerrada e nunca excluídas (histórico preservado)
create or replace function lock_closed_issue() returns trigger
language plpgsql security definer set search_path = public as $$
declare rid uuid := coalesce(new.record_id, old.record_id);
begin
  if tg_op = 'DELETE' then
    raise exception 'Divergências não podem ser excluídas. Marque como resolvida para preservar o histórico.';
  end if;
  if exists (select 1 from monthly_account_records r join monthly_periods p on p.id = r.period_id
              where r.id = rid and p.status = 'encerrada') then
    raise exception 'Competência encerrada: alterações bloqueadas.';
  end if;
  return new;
end $$;
drop trigger if exists trg_lock_issues on reconciliation_issues;
create trigger trg_lock_issues before insert or update or delete on reconciliation_issues
  for each row execute function lock_closed_issue();

-- Auditoria: passa a reconhecer divergências (empresa e competência derivadas do registro)
create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
        n jsonb := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
        k text; cid uuid; pid uuid; rid uuid := coalesce((n->>'id')::uuid, (o->>'id')::uuid);
begin
  if tg_table_name = 'monthly_account_records' then
    pid := coalesce((n->>'period_id')::uuid, (o->>'period_id')::uuid); cid := period_company(pid);
  elsif tg_table_name = 'reconciliation_issues' then
    select r.period_id into pid from monthly_account_records r
     where r.id = coalesce((n->>'record_id')::uuid, (o->>'record_id')::uuid);
    cid := period_company(pid);
  elsif tg_table_name = 'monthly_periods' then
    pid := rid; cid := coalesce((n->>'company_id')::uuid, (o->>'company_id')::uuid);
  elsif tg_table_name = 'companies' then cid := rid;
  else cid := coalesce((n->>'company_id')::uuid, (o->>'company_id')::uuid);
  end if;
  if tg_op = 'INSERT' or tg_op = 'DELETE' then
    insert into audit_logs (user_id, company_id, period_id, table_name, record_id, operation)
    values (auth.uid(), cid, pid, tg_table_name, rid, tg_op);
  else
    for k in select key from jsonb_each(n) loop
      if k not in ('updated_at','updated_by','difference') and n->k is distinct from o->k then
        insert into audit_logs (user_id, company_id, period_id, table_name, record_id, operation, field, old_value, new_value)
        values (auth.uid(), cid, pid, tg_table_name, rid, 'UPDATE', k, o->>k, n->>k);
      end if;
    end loop;
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists aud_issues on reconciliation_issues;
create trigger aud_issues after insert or update or delete on reconciliation_issues
  for each row execute function audit_row();
