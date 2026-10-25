-- ============================================================
-- Link do Drive em cada empresa (ícone de link na aba Empresas)
-- Rode UMA vez no SQL Editor (pode rodar de novo sem problema).
-- Aceita somente links que começam com https:// (ex.: Google Drive, OneDrive, Dropbox).
-- ============================================================
alter table companies add column if not exists drive_url text;
alter table companies drop constraint if exists companies_drive_url_https;
alter table companies add constraint companies_drive_url_https
  check (drive_url is null or (drive_url ~* '^https://[^[:space:]]+$' and length(drive_url) <= 500));
