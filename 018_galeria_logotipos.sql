-- ============================================================
-- Galeria de logotipos da Declaração de Faturamento
-- Rode UMA vez no SQL Editor, DEPOIS do 017 (pode rodar de novo sem problema).
--  * billing_logos: logotipos enviados (ficam salvos e servem para todas as empresas).
--  * billing_settings.logo_id: qual logotipo está ativo na declaração de cada empresa.
-- Ver: qualquer usuário logado. Enviar/excluir: administrador ou contador/supervisor.
-- ============================================================
create table if not exists billing_logos (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Logotipo' check (length(name) <= 120),
  data text not null check (data ~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$' and length(data) <= 600000),
  created_at timestamptz not null default now(),
  created_by uuid references profiles(id) default auth.uid()
);
alter table billing_settings add column if not exists logo_id uuid references billing_logos(id) on delete set null;

-- Leva para a galeria o logotipo que já estava salvo em alguma empresa (versão anterior)
do $$ declare r record; lid uuid; begin
  for r in select company_id, logo from billing_settings where logo is not null and logo_id is null loop
    select id into lid from billing_logos where data = r.logo limit 1;
    if lid is null then insert into billing_logos(name, data) values ('Logotipo', r.logo) returning id into lid; end if;
    update billing_settings set logo_id = lid, logo = null where company_id = r.company_id;
  end loop; end $$;

create or replace function can_manage_logos() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_role_app() in ('admin','supervisor'), false) $$;

drop trigger if exists aud_billing_logos on billing_logos;
create trigger aud_billing_logos after insert or update or delete on billing_logos for each row execute function audit_row();

alter table billing_logos enable row level security;
drop policy if exists billing_logos_select on billing_logos;
drop policy if exists billing_logos_write  on billing_logos;
create policy billing_logos_select on billing_logos for select to authenticated using (true);
create policy billing_logos_write  on billing_logos for all to authenticated using (can_manage_logos()) with check (can_manage_logos());
