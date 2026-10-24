-- ============================================================
-- Maquininhas (terminais de cartão) por empresa
-- Todos os campos são obrigatórios: nome, companhia, SN, POS e descrição.
-- Quem pode cadastrar/editar: administrador e supervisor com acesso à empresa. Todos os vinculados consultam.
-- Maquininhas nunca são excluídas (inativam), para preservar o histórico.
-- ============================================================
create table pos_machines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  provider text not null check (length(trim(provider)) > 0),         -- companhia: Cielo, PagSeguro, Stone, Getnet...
  serial_number text not null check (length(trim(serial_number)) > 0), -- SN (texto: preserva zeros)
  pos_number text not null check (length(trim(pos_number)) > 0),       -- POS (texto)
  description text not null check (length(trim(description)) > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create unique index pos_machines_sn_uq on pos_machines (company_id, lower(provider), serial_number);
create index on pos_machines (company_id);

alter table pos_machines enable row level security;
create policy pos_select on pos_machines for select to authenticated using (has_company_access(company_id));
create policy pos_insert on pos_machines for insert to authenticated
  with check (has_company_access(company_id) and current_role_app() in ('admin','supervisor'));
create policy pos_update on pos_machines for update to authenticated
  using (has_company_access(company_id) and current_role_app() in ('admin','supervisor'))
  with check (has_company_access(company_id) and current_role_app() in ('admin','supervisor'));
-- sem política de DELETE: ninguém exclui

create trigger aud_pos after insert or update or delete on pos_machines
  for each row execute function audit_row();

revoke all on pos_machines from anon;
