-- ATENÇÃO: apaga as tabelas do sistema. Use SOMENTE enquanto o banco estiver vazio (Etapa 1).
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists audit_logs, reconciliation_issues, monthly_account_records,
  monthly_periods, monitored_accounts, account_categories, company_members,
  companies, profiles cascade;
drop function if exists handle_new_user(), guard_profile(), lock_closed_period(),
  touch_record(), audit_row(), has_company_access(uuid), period_company(uuid),
  is_admin(), current_role_app(), cnpj_valid(text) cascade;
drop type if exists app_role, record_status, period_status, group_kind cascade;

-- ============================================================
-- Acompanhamento de Saldos e Conciliação — Etapa 1: Fundação
-- Execute no Supabase: SQL Editor > New query > colar > Run
-- ============================================================

-- ---------- Tipos ----------
create type app_role      as enum ('admin','supervisor','operator');
create type record_status as enum ('pendente','em_andamento','concluido','divergencia','nao_aplicavel');
create type period_status as enum ('aberta','encerrada');
create type group_kind    as enum ('bank','cash','third_party');

-- ---------- Validação de CNPJ (dígitos verificadores) ----------
create or replace function cnpj_valid(c text) returns boolean
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(c,''), '\D', '', 'g'); s int; i int; r int;
        w1 int[] := '{5,4,3,2,9,8,7,6,5,4,3,2}'; w2 int[] := '{6,5,4,3,2,9,8,7,6,5,4,3,2}';
begin
  if length(d) <> 14 or d ~ '^(\d)\1{13}$' then return false; end if;
  s := 0; for i in 1..12 loop s := s + substr(d,i,1)::int * w1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(d,13,1)::int then return false; end if;
  s := 0; for i in 1..13 loop s := s + substr(d,i,1)::int * w2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = substr(d,14,1)::int;
end $$;

-- ---------- Tabelas ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text, email text,
  role app_role not null default 'operator',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table companies (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null,
  trade_name text,
  cnpj text not null unique check (cnpj_valid(cnpj)),
  internal_code text,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references profiles(id)
);

create table company_members (
  company_id uuid not null references companies(id) on delete restrict,
  user_id uuid not null references profiles(id) on delete cascade,
  can_close boolean not null default false,
  primary key (company_id, user_id)
);

create table account_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete restrict,
  kind group_kind not null,
  name text not null,
  counts_as_cash boolean not null default false,  -- só estas entram no total de disponibilidade
  sort_order int not null default 0,
  active boolean not null default true,
  unique (company_id, kind, name)
);

create table monitored_accounts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete restrict,
  category_id uuid not null references account_categories(id) on delete restrict,
  description text not null,
  institution text,
  account_type text,
  account_number text,      -- texto: preserva zeros, barras e hífens
  accounting_code text,     -- texto
  default_responsible uuid references profiles(id),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index on monitored_accounts (company_id, category_id);

create table monthly_periods (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete restrict,
  year int not null check (year between 2000 and 2100),
  month int not null check (month between 1 and 12),
  status period_status not null default 'aberta',
  closed_at timestamptz, closed_by uuid references profiles(id),
  reopened_at timestamptz, reopened_by uuid references profiles(id), reopen_reason text,
  created_at timestamptz not null default now(),
  unique (company_id, year, month)
);

create table monthly_account_records (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references monthly_periods(id) on delete restrict,
  account_id uuid not null references monitored_accounts(id) on delete restrict,
  previous_balance numeric(15,2),            -- NULL = não informado (diferente de 0)
  final_balance numeric(15,2),               -- NULL = não informado (diferente de 0)
  status record_status not null default 'pendente',
  responsible_id uuid references profiles(id),
  notes text,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id),
  unique (period_id, account_id)
);

create table reconciliation_issues (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references monthly_account_records(id) on delete restrict,
  description text not null,
  reference_value numeric(15,2),
  found_value numeric(15,2),
  difference numeric(15,2) generated always as (found_value - reference_value) stored,
  responsible_id uuid references profiles(id),
  identified_at date not null default current_date,
  resolved boolean not null default false,
  resolved_at date,
  notes text
);

create table audit_logs (
  id bigserial primary key,
  at timestamptz not null default now(),
  user_id uuid,
  company_id uuid, period_id uuid,
  table_name text not null, record_id uuid,
  operation text not null, field text,
  old_value text, new_value text
);
create index on audit_logs (company_id, at desc);

-- ---------- Funções de acesso (SECURITY DEFINER evita recursão de RLS) ----------
create or replace function current_role_app() returns app_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and active $$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_role_app() = 'admin', false) $$;

create or replace function has_company_access(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() or exists (
    select 1 from company_members m join profiles p on p.id = m.user_id
    where m.company_id = cid and m.user_id = auth.uid() and p.active) $$;

create or replace function period_company(pid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from monthly_periods where id = pid $$;

-- ---------- Perfil automático; o primeiro usuário vira administrador ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email),
          case when exists (select 1 from profiles) then 'operator'::app_role else 'admin'::app_role end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- Impede autoelevação de perfil ----------
create or replace function guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.role is distinct from old.role or new.active is distinct from old.active
      or new.id is distinct from old.id) and not is_admin() then
    raise exception 'Somente administradores podem alterar perfil de acesso ou situação.';
  end if;
  return new;
end $$;
create trigger trg_guard_profile before update on profiles
  for each row execute function guard_profile();

-- ---------- Trava de competência encerrada ----------
create or replace function lock_closed_period() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid := coalesce(new.period_id, old.period_id);
begin
  if exists (select 1 from monthly_periods where id = pid and status = 'encerrada') then
    raise exception 'Competência encerrada: alterações bloqueadas.';
  end if;
  return coalesce(new, old);
end $$;
create trigger trg_lock_records before insert or update or delete on monthly_account_records
  for each row execute function lock_closed_period();

-- ---------- Controle de campos e auditoria genérica ----------
create or replace function touch_record() returns trigger
language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger trg_touch before update on monthly_account_records
  for each row execute function touch_record();

create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
        n jsonb := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
        k text; cid uuid; pid uuid; rid uuid := coalesce((n->>'id')::uuid, (o->>'id')::uuid);
begin
  if tg_table_name = 'monthly_account_records' then
    pid := coalesce((n->>'period_id')::uuid, (o->>'period_id')::uuid); cid := period_company(pid);
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
      if k not in ('updated_at','updated_by') and n->k is distinct from o->k then
        insert into audit_logs (user_id, company_id, period_id, table_name, record_id, operation, field, old_value, new_value)
        values (auth.uid(), cid, pid, tg_table_name, rid, 'UPDATE', k, o->>k, n->>k);
      end if;
    end loop;
  end if;
  return coalesce(new, old);
end $$;

create trigger aud_companies after insert or update or delete on companies for each row execute function audit_row();
create trigger aud_accounts  after insert or update or delete on monitored_accounts for each row execute function audit_row();
create trigger aud_periods   after insert or update or delete on monthly_periods for each row execute function audit_row();
create trigger aud_records   after insert or update or delete on monthly_account_records for each row execute function audit_row();

-- ---------- RLS ----------
alter table profiles                enable row level security;
alter table companies               enable row level security;
alter table company_members         enable row level security;
alter table account_categories      enable row level security;
alter table monitored_accounts      enable row level security;
alter table monthly_periods         enable row level security;
alter table monthly_account_records enable row level security;
alter table reconciliation_issues   enable row level security;
alter table audit_logs              enable row level security;

-- profiles: cada um vê o próprio; admin vê todos; colegas das mesmas empresas aparecem como responsáveis
create policy profiles_select on profiles for select to authenticated using (
  id = auth.uid() or is_admin() or exists (
    select 1 from company_members a join company_members b on a.company_id = b.company_id
    where a.user_id = auth.uid() and b.user_id = profiles.id));
create policy profiles_update_self on profiles for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());

-- companies / membros: leitura por acesso; escrita só administrador
create policy companies_select on companies for select to authenticated using (has_company_access(id));
create policy companies_write  on companies for all to authenticated using (is_admin()) with check (is_admin());
create policy members_select   on company_members for select to authenticated using (user_id = auth.uid() or is_admin());
create policy members_write    on company_members for all to authenticated using (is_admin()) with check (is_admin());

-- estrutura (categorias e contas): leitura por acesso; escrita só administrador
create policy categories_select on account_categories for select to authenticated using (has_company_access(company_id));
create policy categories_write  on account_categories for all to authenticated using (is_admin()) with check (is_admin());
create policy accounts_select   on monitored_accounts for select to authenticated using (has_company_access(company_id));
create policy accounts_write    on monitored_accounts for all to authenticated using (is_admin()) with check (is_admin());

-- competências: administrador e supervisor criam/atualizam (encerrar/reabrir será via função na Etapa 3)
create policy periods_select on monthly_periods for select to authenticated using (has_company_access(company_id));
create policy periods_insert on monthly_periods for insert to authenticated
  with check (has_company_access(company_id) and current_role_app() in ('admin','supervisor'));
create policy periods_update on monthly_periods for update to authenticated
  using (has_company_access(company_id) and current_role_app() in ('admin','supervisor'))
  with check (has_company_access(company_id) and current_role_app() in ('admin','supervisor'));

-- registros mensais e divergências: qualquer perfil com acesso à empresa (trava de encerramento no trigger)
create policy records_select on monthly_account_records for select to authenticated using (has_company_access(period_company(period_id)));
create policy records_write  on monthly_account_records for all to authenticated
  using (has_company_access(period_company(period_id))) with check (has_company_access(period_company(period_id)));
create policy issues_all on reconciliation_issues for all to authenticated
  using (exists (select 1 from monthly_account_records r where r.id = record_id and has_company_access(period_company(r.period_id))))
  with check (exists (select 1 from monthly_account_records r where r.id = record_id and has_company_access(period_company(r.period_id))));

-- auditoria: somente leitura para administrador e supervisor; ninguém grava direto
create policy audit_select on audit_logs for select to authenticated
  using (current_role_app() in ('admin','supervisor') and (is_admin() or has_company_access(company_id)));

-- nenhum acesso anônimo
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
revoke insert, update, delete on audit_logs from authenticated;
