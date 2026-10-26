-- ============================================================
-- Declaração de Faturamento
-- Rode UMA vez no SQL Editor (pode rodar de novo sem problema).
--  * Endereço no cadastro da empresa (usado no texto da declaração).
--  * billing_settings: assinantes, cidade, logotipo e categorias que contam como receita, por empresa.
--  * billing_month_values: valores digitados à mão na declaração (substituem o valor automático do mês).
-- Leitura: quem tem acesso à empresa. Gravação: administrador ou contador/supervisor vinculado à empresa.
-- ============================================================

-- ---------- Endereço da empresa ----------
alter table companies add column if not exists address_street   text;
alter table companies add column if not exists address_number   text;
alter table companies add column if not exists address_district text;
alter table companies add column if not exists address_city     text;
alter table companies add column if not exists address_uf       text;
alter table companies drop constraint if exists companies_address_uf_check;
alter table companies add constraint companies_address_uf_check
  check (address_uf is null or address_uf ~ '^[A-Z]{2}$');

-- ---------- Quem pode gravar (admin, ou supervisor da empresa) ----------
create or replace function can_edit_billing(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() or (current_role_app() = 'supervisor' and has_company_access(cid)) $$;

-- ---------- Configurações da declaração ----------
create table if not exists billing_settings (
  company_id uuid primary key references companies(id) on delete restrict,
  accountant_name text,
  accountant_role text not null default 'Contador',
  accountant_crc  text,
  rep_name text,
  rep_role text not null default 'Presidente',
  rep_cpf  text check (rep_cpf is null or rep_cpf ~ '^\d{11}$'),
  place text not null default 'Campina Grande/PB',
  logo text check (logo is null or (logo ~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$' and length(logo) <= 600000)),
  revenue_category_ids uuid[] not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id) default auth.uid()
);

-- ---------- Valores mensais editados à mão ----------
create table if not exists billing_month_values (
  company_id uuid not null references companies(id) on delete restrict,
  year  int not null check (year between 2000 and 2100),
  month int not null check (month between 1 and 12),
  amount numeric(15,2) not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id) default auth.uid(),
  primary key (company_id, year, month)
);

create or replace function touch_billing() returns trigger
language plpgsql as $$ begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists touch_billing_settings on billing_settings;
create trigger touch_billing_settings before insert or update on billing_settings for each row execute function touch_billing();
drop trigger if exists touch_billing_values on billing_month_values;
create trigger touch_billing_values before insert or update on billing_month_values for each row execute function touch_billing();

-- Auditoria (quem alterou o quê)
drop trigger if exists aud_billing_settings on billing_settings;
create trigger aud_billing_settings after insert or update or delete on billing_settings for each row execute function audit_row();
drop trigger if exists aud_billing_values on billing_month_values;
create trigger aud_billing_values after insert or update or delete on billing_month_values for each row execute function audit_row();

-- ---------- RLS ----------
alter table billing_settings     enable row level security;
alter table billing_month_values enable row level security;

drop policy if exists billing_settings_select on billing_settings;
drop policy if exists billing_settings_write  on billing_settings;
create policy billing_settings_select on billing_settings for select to authenticated using (has_company_access(company_id));
create policy billing_settings_write  on billing_settings for all to authenticated
  using (can_edit_billing(company_id)) with check (can_edit_billing(company_id));

drop policy if exists billing_values_select on billing_month_values;
drop policy if exists billing_values_write  on billing_month_values;
create policy billing_values_select on billing_month_values for select to authenticated using (has_company_access(company_id));
create policy billing_values_write  on billing_month_values for all to authenticated
  using (can_edit_billing(company_id)) with check (can_edit_billing(company_id));
