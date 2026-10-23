-- ============================================================
-- Etapa 3.1 — Encerramento e reabertura de competência
-- A situação da competência só muda pelas funções abaixo (checagem no banco, não só na tela).
-- ============================================================

-- Impede alterar situação/encerramento por UPDATE direto (mesmo para supervisor/administrador)
create or replace function guard_period_status() returns trigger
language plpgsql as $$
begin
  if (new.status is distinct from old.status
      or new.closed_at is distinct from old.closed_at or new.closed_by is distinct from old.closed_by
      or new.reopened_at is distinct from old.reopened_at or new.reopened_by is distinct from old.reopened_by
      or new.reopen_reason is distinct from old.reopen_reason
      or new.company_id <> old.company_id or new.year <> old.year or new.month <> old.month)
     and coalesce(current_setting('app.period_op', true), '') <> '1' then
    raise exception 'Use o encerramento e a reabertura da competência para alterar a situação dela.';
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_period on monthly_periods;
create trigger trg_guard_period before update on monthly_periods
  for each row execute function guard_period_status();

-- Encerrar: administrador, ou supervisor marcado com "pode encerrar" na empresa.
-- Com pendências/divergências abertas só é aceito com p_force = true e apenas para administrador.
create or replace function close_period(p_period uuid, p_force boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid; st period_status; pend int; iss int; r app_role; okc boolean;
begin
  select company_id, status into cid, st from monthly_periods where id = p_period;
  if cid is null then raise exception 'Competência não encontrada.'; end if;
  r := current_role_app();
  select can_close into okc from company_members where company_id = cid and user_id = auth.uid();
  if not (r = 'admin' or (r = 'supervisor' and coalesce(okc, false))) then
    raise exception 'Sem autorização para encerrar esta competência.';
  end if;
  if st = 'encerrada' then raise exception 'A competência já está encerrada.'; end if;

  select count(*) into pend from monthly_account_records
   where period_id = p_period and status in ('pendente','em_andamento','divergencia');
  select count(*) into iss from reconciliation_issues i join monthly_account_records x on x.id = i.record_id
   where x.period_id = p_period and not i.resolved;
  if pend > 0 or iss > 0 then
    if not p_force then
      raise exception 'Existem pendências (% itens) e % divergência(s) aberta(s). Confirme o encerramento com pendências.', pend, iss;
    end if;
    if r <> 'admin' then raise exception 'Somente administradores podem encerrar com pendências.'; end if;
  end if;

  perform set_config('app.period_op', '1', true);
  update monthly_periods set status = 'encerrada', closed_at = now(), closed_by = auth.uid() where id = p_period;
end $$;

-- Reabrir: somente administrador, com justificativa (fica registrada na auditoria).
create or replace function reopen_period(p_period uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare st period_status;
begin
  if current_role_app() is distinct from 'admin' then raise exception 'Somente administradores podem reabrir competências.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then raise exception 'Informe uma justificativa com pelo menos 10 caracteres.'; end if;
  select status into st from monthly_periods where id = p_period;
  if st is null then raise exception 'Competência não encontrada.'; end if;
  if st <> 'encerrada' then raise exception 'A competência não está encerrada.'; end if;

  perform set_config('app.period_op', '1', true);
  update monthly_periods set status = 'aberta', closed_at = null, closed_by = null,
         reopened_at = now(), reopened_by = auth.uid(), reopen_reason = trim(p_reason)
   where id = p_period;
end $$;

revoke execute on function close_period(uuid, boolean), reopen_period(uuid, text) from public, anon;
grant  execute on function close_period(uuid, boolean), reopen_period(uuid, text) to authenticated;
