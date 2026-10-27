-- =====================================================================
-- Evidencia hodín + upomienky: kompletná databáza pre Supabase
-- Spusti celý skript v Supabase → SQL Editor → Run
-- =====================================================================

-- ---------- 1) Tabuľky ----------

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  role        text not null default 'member' check (role in ('owner', 'member')),
  hourly_rate numeric,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table workplaces (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  address          text,
  active           boolean not null default true,
  tracks_time      boolean not null default true,  -- false = len odškrtnutie návštevy, bez stopiek
  visit_every_days int,                            -- null = bez pravidelnej návštevy
  created_at       timestamptz not null default now()
);

create table time_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id),
  workplace_id  uuid not null references workplaces(id),
  work_date     date not null,
  start_time    timestamptz,          -- pri návšteve null
  end_time      timestamptz,          -- pri návšteve null
  hours         numeric,              -- pri návšteve null
  break_minutes int not null default 0,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table reminders (
  id           uuid primary key default gen_random_uuid(),
  created_by   uuid not null references profiles(id),
  assigned_to  uuid not null references profiles(id),
  title        text,
  description  text not null,
  due_at       timestamptz,
  status       text not null default 'open' check (status in ('open', 'done', 'dismissed')),
  seen_at      timestamptz,           -- null = ešte nevidené (nová)
  completed_at timestamptz,
  created_at   timestamptz not null default now()
);

-- ---------- 2) Indexy ----------

create index on time_entries (user_id, work_date);
create index on time_entries (workplace_id, work_date);
create index on reminders (assigned_to, status, due_at);
create index on reminders (created_by, created_at);

-- ---------- 3) Pomocná funkcia: je prihlásený používateľ owner? ----------

create or replace function is_owner() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner');
$$;

-- ---------- 4) Zabezpečenie (Row Level Security) ----------

alter table profiles     enable row level security;
alter table workplaces   enable row level security;
alter table time_entries enable row level security;
alter table reminders    enable row level security;

-- profiles: každý vidí seba, owner vidí a spravuje všetkých
create policy profiles_read on profiles
  for select to authenticated using (id = auth.uid() or is_owner());
create policy profiles_owner_write on profiles
  for all to authenticated using (is_owner()) with check (is_owner());

-- workplaces: čítajú všetci prihlásení, zapisuje len owner
create policy workplaces_read on workplaces
  for select to authenticated using (true);
create policy workplaces_owner_write on workplaces
  for all to authenticated using (is_owner()) with check (is_owner());

-- time_entries: člen svoje, owner všetky na čítanie
create policy te_own on time_entries
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy te_owner_read on time_entries
  for select to authenticated using (is_owner());

-- reminders: člen vytvára a vidí svoje, adresát (owner) vidí a vybavuje tie pre neho
create policy rem_insert on reminders
  for insert to authenticated with check (created_by = auth.uid());
create policy rem_read on reminders
  for select to authenticated using (created_by = auth.uid() or assigned_to = auth.uid());
create policy rem_update on reminders
  for update to authenticated using (assigned_to = auth.uid());

-- ---------- 5) Upomienky: automatické priradenie ownerovi ----------
-- Člen z klienta nemôže podvrhnúť autora, adresáta ani stav.

create or replace function set_reminder_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.created_by  := auth.uid();
  new.assigned_to := (select id from profiles where role = 'owner' limit 1);
  new.status      := 'open';
  return new;
end;
$$;

create trigger reminders_set_owner
  before insert on reminders
  for each row execute function set_reminder_owner();

-- Realtime pre nové upomienky
alter publication supabase_realtime add table reminders;

-- ---------- 6) Pracoviská ----------

insert into workplaces (name, address, active, tracks_time, visit_every_days) values
  ('Arkadyhof',          null,                              true, true,  null),
  ('Objekt Keramik',     'Rožňavská 1, Bratislava',         true, false, 7),
  ('Pekná cesta 3 a 5',  'Pekná cesta 3 a 5, Bratislava',   true, false, 7);

-- ---------- 7) Profily používateľov ----------
-- Najprv vytvor účty v Authentication → Users (e-mail v tvare meno.priezvisko@example.com),
-- potom pre každého spusti riadok ako tento (uprav e-mail a meno):

-- insert into profiles (id, full_name, role)
-- select id, 'Wwz', 'owner' from auth.users where email = 'wwz@example.com';

-- insert into profiles (id, full_name, role)
-- select id, 'Peter', 'member' from auth.users where email = 'peter@example.com';

-- ---------- 8) Registrácia: profil sa vytvorí automaticky ----------
-- Po vytvorení účtu v apke (meno + 4-miestny PIN) vznikne profil vždy ako member.
-- Rolu owner nastavíš ručne (pozri nižšie).

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), split_part(new.email, '@', 1)),
    'member'
  );
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.set_reminder_owner() from public, anon, authenticated;
revoke execute on function public.is_owner() from public, anon;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Nastavenie hlavného používateľa (spusti po vlastnej registrácii v apke, uprav meno):
-- update profiles set role = 'owner' where full_name = 'Wwz';

-- ---------- 9) Vlastné miesta používateľov (odkaz + obrázok) ----------
-- Ak už máš databázu vytvorenú skôr, spusti len migrations/2026-10-27_personal_places.sql
alter table public.workplaces
  add column if not exists url text,
  add column if not exists image_url text,
  add column if not exists created_by uuid references public.profiles(id);

alter table public.workplaces
  add constraint workplaces_name_len check (char_length(name) between 1 and 120),
  add constraint workplaces_url_http check (url is null or url ~* '^https?://'),
  add constraint workplaces_image_http check (image_url is null or image_url ~* '^https?://'),
  add constraint workplaces_visit_days check (visit_every_days is null or visit_every_days between 1 and 365);

create index if not exists workplaces_created_by_idx on public.workplaces (created_by);

drop policy if exists workplaces_read on public.workplaces;
drop policy if exists workplaces_owner_write on public.workplaces;

-- vidím zdieľané a svoje; owner vidí všetky
create policy workplaces_read on public.workplaces
  for select to authenticated
  using (created_by is null or created_by = (select auth.uid()) or public.is_owner());

-- vytváram len vlastné miesta; zdieľané (created_by null) smie vytvoriť len owner
create policy workplaces_insert on public.workplaces
  for insert to authenticated
  with check (created_by = (select auth.uid()) or public.is_owner());

-- upravujem svoje; owner všetky
create policy workplaces_update on public.workplaces
  for update to authenticated
  using (created_by = (select auth.uid()) or public.is_owner())
  with check (created_by = (select auth.uid()) or public.is_owner());

create policy workplaces_delete on public.workplaces
  for delete to authenticated
  using (created_by = (select auth.uid()) or public.is_owner());
