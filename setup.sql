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

-- ============================================================
-- 10) Marína rozpis (verejný kalendár a rezervácie)
-- ============================================================
create table if not exists public.marina_free_days (
  day date primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.marina_bookings (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  customer_name text not null check (char_length(btrim(customer_name)) between 1 and 80),
  destination text not null check (char_length(btrim(destination)) between 1 and 120),
  note text check (note is null or char_length(note) <= 1000),
  status text not null default 'new' check (status in ('new', 'confirmed', 'cancelled')),
  created_at timestamptz not null default now()
);

-- jeden aktívny termín na deň (zrušená rezervácia deň uvoľní)
create unique index if not exists marina_bookings_one_per_day
  on public.marina_bookings (day) where status <> 'cancelled';

alter table public.marina_free_days enable row level security;
alter table public.marina_bookings enable row level security;

drop policy if exists marina_free_days_owner on public.marina_free_days;
create policy marina_free_days_owner on public.marina_free_days
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

drop policy if exists marina_bookings_owner on public.marina_bookings;
create policy marina_bookings_owner on public.marina_bookings
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

-- Verejné: voľné dni v rozsahu (bez dní, ktoré už niekto rezervoval, a bez minulosti)
create or replace function public.marina_open_days(p_from date, p_to date)
returns setof date
language sql stable security definer set search_path = public
as $$
  select f.day
  from marina_free_days f
  where f.day between p_from and least(p_to, p_from + 400)
    and f.day >= (now() at time zone 'Europe/Bratislava')::date
    and not exists (select 1 from marina_bookings b where b.day = f.day and b.status <> 'cancelled')
  order by f.day;
$$;

-- Verejné: vytvorenie rezervácie
create or replace function public.marina_book(p_day date, p_name text, p_destination text, p_note text default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_day is null or p_day < (now() at time zone 'Europe/Bratislava')::date then
    raise exception 'bad_day';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 80
     or char_length(btrim(coalesce(p_destination, ''))) not between 1 and 120
     or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'bad_input';
  end if;
  if not exists (select 1 from marina_free_days where day = p_day) then
    raise exception 'day_not_free';
  end if;
  -- jednoduchá ochrana pred zaspamovaním
  if (select count(*) from marina_bookings where status = 'new' and lower(customer_name) = lower(btrim(p_name))) >= 3 then
    raise exception 'too_many';
  end if;
  begin
    insert into marina_bookings (day, customer_name, destination, note)
    values (p_day, btrim(p_name), btrim(p_destination), nullif(btrim(coalesce(p_note, '')), ''));
  exception when unique_violation then
    raise exception 'day_taken';
  end;
end;
$$;

revoke all on function public.marina_open_days(date, date) from public;
revoke all on function public.marina_book(date, text, text, text) from public;
grant execute on function public.marina_open_days(date, date) to anon, authenticated;
grant execute on function public.marina_book(date, text, text, text) to anon, authenticated;

-- ============================================================
-- 11) Profil Maríny a upozornenia (účet a tajné hodnoty: migrations/marina_account.template.sql)
-- ============================================================
-- 1) Nová rola 'marina': spravuje len rozpis (voľné dni a rezervácie), nevidí hodiny ostatných
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner', 'member', 'marina'));

create or replace function public.is_marina() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'marina');
$$;
revoke execute on function public.is_marina() from public, anon;

drop policy if exists marina_free_days_owner on public.marina_free_days;
drop policy if exists marina_free_days_manage on public.marina_free_days;
create policy marina_free_days_manage on public.marina_free_days
  for all to authenticated
  using (public.is_owner() or public.is_marina()) with check (public.is_owner() or public.is_marina());

drop policy if exists marina_bookings_owner on public.marina_bookings;
drop policy if exists marina_bookings_manage on public.marina_bookings;
create policy marina_bookings_manage on public.marina_bookings
  for all to authenticated
  using (public.is_owner() or public.is_marina()) with check (public.is_owner() or public.is_marina());

-- 2) Nastavenia (tajná téma pre upozornenia). Bez politík = nikto z klienta ich nevidí, číta ich len databáza.
create table if not exists public.marina_settings (
  key text primary key,
  value text not null
);
alter table public.marina_settings enable row level security;

-- 3) Upozornenie hneď po vytvorení rezervácie: push cez ntfy.sh (apka ntfy v telefóne Maríny)
create extension if not exists pg_net with schema extensions;

create or replace function public.marina_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_topic text := (select value from marina_settings where key = 'ntfy_topic');
  v_url   text := (select value from marina_settings where key = 'app_url');
  v_msg   text;
begin
  if v_topic is null then return new; end if;
  v_msg := 'Dátum: ' || to_char(new.day, 'DD.MM.YYYY')
        || E'\nMeno: ' || new.customer_name
        || E'\nKam: ' || new.destination
        || E'\nPoznámka: ' || coalesce(new.note, '–');
  begin
    perform net.http_post(
      url := 'https://ntfy.sh',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_strip_nulls(jsonb_build_object(
        'topic', v_topic,
        'title', 'Nová rezervácia',
        'message', v_msg,
        'priority', 4,
        'tags', jsonb_build_array('calendar'),
        'click', v_url
      ))
    );
  exception when others then
    null;  -- chyba upozornenia nikdy nesmie zablokovať rezerváciu
  end;
  return new;
end;
$$;
revoke execute on function public.marina_notify() from public, anon, authenticated;

drop trigger if exists marina_booking_notify on public.marina_bookings;
create trigger marina_booking_notify
  after insert on public.marina_bookings
  for each row execute function public.marina_notify();

-- 4) Živé upozornenie v otvorenej apke (Realtime)
do $$ begin
  alter publication supabase_realtime add table public.marina_bookings;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ============================================================
-- 12) Platba 2,50 € pred rezerváciou (Edge funkcie marina-checkout a stripe-webhook)
-- ============================================================
alter table public.marina_bookings
  add column if not exists paid_at timestamptz,
  add column if not exists payment_ref text,
  add column if not exists amount_cents integer;

alter table public.marina_bookings drop constraint if exists marina_bookings_status_check;
alter table public.marina_bookings add constraint marina_bookings_status_check
  check (status in ('pending_payment', 'new', 'confirmed', 'cancelled'));

-- Verejné funkcie, cez ktoré sa dalo rezervovať bez platby, sa zrušia
drop function if exists public.marina_book(date, text, text, text);

-- Voľné dni: nezaplatená rezervácia drží deň len 30 minút
create or replace function public.marina_open_days(p_from date, p_to date)
returns setof date
language sql stable security definer set search_path = public
as $$
  select f.day
  from marina_free_days f
  where f.day between p_from and least(p_to, p_from + 400)
    and f.day >= (now() at time zone 'Europe/Bratislava')::date
    and not exists (
      select 1 from marina_bookings b
      where b.day = f.day and b.status <> 'cancelled'
        and not (b.status = 'pending_payment' and b.created_at < now() - interval '30 minutes'))
  order by f.day;
$$;

-- Len server (service_role): založí rezerváciu čakajúcu na platbu a vráti jej id
create or replace function public.marina_create_pending(p_day date, p_name text, p_destination text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if p_day is null or p_day < (now() at time zone 'Europe/Bratislava')::date then raise exception 'bad_day'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 80
     or char_length(btrim(coalesce(p_destination, ''))) not between 1 and 120
     or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'bad_input';
  end if;
  if not exists (select 1 from marina_free_days where day = p_day) then raise exception 'day_not_free'; end if;
  -- po vypršaní držania sa deň uvoľní
  update marina_bookings set status = 'cancelled'
    where day = p_day and status = 'pending_payment' and created_at < now() - interval '30 minutes';
  -- ochrana pred blokovaním termínov nezaplatenými rezerváciami
  if (select count(*) from marina_bookings where status = 'pending_payment' and created_at > now() - interval '30 minutes') >= 10 then
    raise exception 'busy';
  end if;
  if (select count(*) from marina_bookings where status = 'new' and lower(customer_name) = lower(btrim(p_name))) >= 3 then
    raise exception 'too_many';
  end if;
  begin
    insert into marina_bookings (day, customer_name, destination, note, status, amount_cents)
    values (p_day, btrim(p_name), btrim(p_destination), nullif(btrim(coalesce(p_note, '')), ''), 'pending_payment', 250)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'day_taken';
  end;
  return v_id;
end;
$$;

-- Len server: platba prebehla -> rezervácia sa odošle Maríne (stav 'new' spustí upozornenie)
-- Vráti 'ok', 'already' (už spracované) alebo 'conflict' (deň medzitým obsadila iná rezervácia: treba vrátiť peniaze)
create or replace function public.marina_mark_paid(p_id uuid, p_ref text, p_amount integer)
returns text
language plpgsql security definer set search_path = public
as $$
declare v_status text;
begin
  select status into v_status from marina_bookings where id = p_id for update;
  if v_status is null then return 'conflict'; end if;
  if v_status in ('new', 'confirmed') then return 'already'; end if;
  begin
    update marina_bookings
      set status = 'new', paid_at = now(), payment_ref = p_ref, amount_cents = p_amount
      where id = p_id;
  exception when unique_violation then
    update marina_bookings set payment_ref = p_ref, paid_at = now(), amount_cents = p_amount where id = p_id;
    return 'conflict';
  end;
  return 'ok';
end;
$$;

-- Len server: nezaplatená rezervácia sa zruší (zrušená platba, vypršaná relácia)
create or replace function public.marina_cancel_pending(p_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update marina_bookings set status = 'cancelled' where id = p_id and status = 'pending_payment';
$$;

-- Verejné: stav rezervácie podľa id (id je náhodné a neuhádnuteľné), na zobrazenie výsledku po platbe
create or replace function public.marina_booking_status(p_id uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select case when status in ('new', 'confirmed') then 'paid' else status end from marina_bookings where id = p_id;
$$;

revoke all on function public.marina_create_pending(date, text, text, text) from public, anon, authenticated;
revoke all on function public.marina_mark_paid(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.marina_cancel_pending(uuid) from public, anon, authenticated;
grant execute on function public.marina_create_pending(date, text, text, text) to service_role;
grant execute on function public.marina_mark_paid(uuid, text, integer) to service_role;
grant execute on function public.marina_cancel_pending(uuid) to service_role;
revoke all on function public.marina_booking_status(uuid) from public;
grant execute on function public.marina_booking_status(uuid) to anon, authenticated;

-- Upozornenie Maríne až po zaplatení (prechod 'pending_payment' -> 'new'), nie pri založení rezervácie
create or replace function public.marina_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_topic text := (select value from marina_settings where key = 'ntfy_topic');
  v_url   text := (select value from marina_settings where key = 'app_url');
  v_msg   text;
begin
  if new.status <> 'new' then return new; end if;
  if tg_op = 'UPDATE' and old.status <> 'pending_payment' then return new; end if;
  if v_topic is null then return new; end if;
  v_msg := 'Dátum: ' || to_char(new.day, 'DD.MM.YYYY')
        || E'\nMeno: ' || new.customer_name
        || E'\nKam: ' || new.destination
        || E'\nPoznámka: ' || coalesce(new.note, '–')
        || case when new.payment_ref = 'qr'
             then E'\nPlatba QR 2.50 € – ešte neoverená, over ju v banke. Správa: R-' || upper(left(replace(new.id::text, '-', ''), 6))
             else E'\nZaplatené: ' || to_char(coalesce(new.amount_cents, 0) / 100.0, 'FM0.00') || ' €' end;
  begin
    perform net.http_post(
      url := 'https://ntfy.sh',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_strip_nulls(jsonb_build_object(
        'topic', v_topic, 'title', 'Nová rezervácia', 'message', v_msg,
        'priority', 4, 'tags', jsonb_build_array('calendar'), 'click', v_url))
    );
  exception when others then
    null;  -- chyba upozornenia nikdy nesmie zablokovať rezerváciu
  end;
  return new;
end;
$$;
revoke execute on function public.marina_notify() from public, anon, authenticated;

drop trigger if exists marina_booking_notify on public.marina_bookings;
create trigger marina_booking_notify
  after insert or update of status on public.marina_bookings
  for each row execute function public.marina_notify();

-- ============================================================
-- 13) Záznam práce chránený 6-miestnym kódom (kód nastav: migrations/work_code.template.sql)
-- ============================================================
alter table public.profiles add column if not exists work_access boolean not null default false;
update public.profiles set work_access = true where role = 'owner';

create or replace function public.has_work_access() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and (role = 'owner' or work_access));
$$;
revoke execute on function public.has_work_access() from public, anon;

drop policy if exists te_own on public.time_entries;
create policy te_own on public.time_entries
  for all to authenticated
  using (user_id = (select auth.uid()) and public.has_work_access())
  with check (user_id = (select auth.uid()) and public.has_work_access());

create table if not exists public.work_unlock_attempts (
  user_id uuid not null,
  at timestamptz not null default now()
);
alter table public.work_unlock_attempts enable row level security;  -- bez politík: klient ju nevidí

create or replace function public.unlock_work(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_salt text := (select value from marina_settings where key = 'work_code_salt');
  v_hash text := (select value from marina_settings where key = 'work_code_hash');
begin
  select role into v_role from profiles where id = v_uid;
  if v_uid is null or v_role is null then return 'auth'; end if;
  if v_role = 'marina' then return 'forbidden'; end if;
  if v_hash is null then return 'not_configured'; end if;
  if (select count(*) from work_unlock_attempts where user_id = v_uid and at > now() - interval '1 hour') >= 5 then
    return 'locked';
  end if;
  if encode(sha256(convert_to(v_salt || coalesce(p_code, ''), 'utf8')), 'hex') = v_hash then
    update profiles set work_access = true where id = v_uid;
    delete from work_unlock_attempts where user_id = v_uid;
    return 'ok';
  end if;
  insert into work_unlock_attempts (user_id) values (v_uid);
  return 'wrong';
end;
$$;
revoke all on function public.unlock_work(text) from public, anon;
grant execute on function public.unlock_work(text) to authenticated;

-- ============================================================
-- 15) Predvolený kód pre Záznam práce: 101010 (vlastný kód: migrations/work_code.template.sql)
-- ============================================================
create or replace function public.unlock_work(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  -- predvolený kód je 101010; vlastný kód nastavíš šablónou migrations/work_code.template.sql
  v_salt text := coalesce((select value from marina_settings where key = 'work_code_salt'), 'apka-default');
  v_hash text := coalesce((select value from marina_settings where key = 'work_code_hash'),
                          encode(sha256(convert_to('apka-default' || '101010', 'utf8')), 'hex'));
begin
  select role into v_role from profiles where id = v_uid;
  if v_uid is null or v_role is null then return 'auth'; end if;
  if v_role = 'marina' then return 'forbidden'; end if;
  if (select count(*) from work_unlock_attempts where user_id = v_uid and at > now() - interval '1 hour') >= 5 then
    return 'locked';
  end if;
  if encode(sha256(convert_to(v_salt || coalesce(p_code, ''), 'utf8')), 'hex') = v_hash then
    update profiles set work_access = true where id = v_uid;
    delete from work_unlock_attempts where user_id = v_uid;
    return 'ok';
  end if;
  insert into work_unlock_attempts (user_id) values (v_uid);
  return 'wrong';
end;
$$;
revoke all on function public.unlock_work(text) from public, anon;
grant execute on function public.unlock_work(text) to authenticated;

-- ============================================================
-- 16) Všetky dni voľné, zablokované dni, druhý kód pre správu rezervácií (kód: migrations/marina_admin_code.template.sql)
-- ============================================================
-- 1) Zablokované dni (všetky ostatné dni od dneška sú voľné)
create table if not exists public.marina_blocked_days (
  day date primary key,
  created_at timestamptz not null default now()
);
alter table public.marina_blocked_days enable row level security;

-- 2) Prístup k správe rezervácií: rola owner/marina, alebo odomknutý druhým kódom
alter table public.profiles add column if not exists marina_access boolean not null default false;

create or replace function public.has_marina_access() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid()
                 and (role in ('owner', 'marina') or marina_access));
$$;
revoke execute on function public.has_marina_access() from public, anon;

drop policy if exists marina_bookings_manage on public.marina_bookings;
create policy marina_bookings_manage on public.marina_bookings
  for all to authenticated
  using (public.has_marina_access()) with check (public.has_marina_access());

drop policy if exists marina_blocked_days_manage on public.marina_blocked_days;
create policy marina_blocked_days_manage on public.marina_blocked_days
  for all to authenticated
  using (public.has_marina_access()) with check (public.has_marina_access());

-- 3) Verejné: voľné dni = všetky dni od dneška okrem zablokovaných a už rezervovaných
create or replace function public.marina_open_days(p_from date, p_to date)
returns setof date
language sql stable security definer set search_path = public
as $$
  select d::date
  from generate_series(
         greatest(p_from, (now() at time zone 'Europe/Bratislava')::date),
         least(p_to, p_from + 400), interval '1 day') d
  where not exists (select 1 from marina_blocked_days x where x.day = d::date)
    and not exists (
      select 1 from marina_bookings b
      where b.day = d::date and b.status <> 'cancelled'
        and not (b.status = 'pending_payment' and b.created_at < now() - interval '30 minutes'))
  order by 1;
$$;

-- 4) Vytvorenie rezervácie: deň nesmie byť zablokovaný (namiesto zoznamu voľných dní)
create or replace function public.marina_create_pending(p_day date, p_name text, p_destination text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if p_day is null or p_day < (now() at time zone 'Europe/Bratislava')::date then raise exception 'bad_day'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 80
     or char_length(btrim(coalesce(p_destination, ''))) not between 1 and 120
     or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'bad_input';
  end if;
  if exists (select 1 from marina_blocked_days where day = p_day) then raise exception 'day_not_free'; end if;
  -- po vypršaní držania sa deň uvoľní
  update marina_bookings set status = 'cancelled'
    where day = p_day and status = 'pending_payment' and created_at < now() - interval '30 minutes';
  -- ochrana pred blokovaním termínov nezaplatenými rezerváciami
  if (select count(*) from marina_bookings where status = 'pending_payment' and created_at > now() - interval '30 minutes') >= 10 then
    raise exception 'busy';
  end if;
  if (select count(*) from marina_bookings where status = 'new' and lower(customer_name) = lower(btrim(p_name))) >= 3 then
    raise exception 'too_many';
  end if;
  begin
    insert into marina_bookings (day, customer_name, destination, note, status, amount_cents)
    values (p_day, btrim(p_name), btrim(p_destination), nullif(btrim(coalesce(p_note, '')), ''), 'pending_payment', 250)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'day_taken';
  end;
  return v_id;
end;
$$;

revoke all on function public.marina_create_pending(date, text, text, text) from public, anon, authenticated;
grant execute on function public.marina_create_pending(date, text, text, text) to service_role;

-- 5) Odomknutie kódom: prvý kód odomkne Záznam práce, druhý správu rezervácií (prijať/odmietnuť)
create or replace function public.unlock_work(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_code text := coalesce(p_code, '');
  v_salt text := coalesce((select value from marina_settings where key = 'work_code_salt'), 'apka-default');
  v_hash text := coalesce((select value from marina_settings where key = 'work_code_hash'),
                          encode(sha256(convert_to('apka-default' || '101010', 'utf8')), 'hex'));
  v_asalt text := (select value from marina_settings where key = 'marina_admin_salt');
  v_ahash text := (select value from marina_settings where key = 'marina_admin_hash');
begin
  select role into v_role from profiles where id = v_uid;
  if v_uid is null or v_role is null then return 'auth'; end if;
  if v_role = 'marina' then return 'forbidden'; end if;
  if (select count(*) from work_unlock_attempts where user_id = v_uid and at > now() - interval '1 hour') >= 5 then
    return 'locked';
  end if;
  if encode(sha256(convert_to(v_salt || v_code, 'utf8')), 'hex') = v_hash then
    update profiles set work_access = true where id = v_uid;
    delete from work_unlock_attempts where user_id = v_uid;
    return 'ok';
  end if;
  if v_ahash is not null and encode(sha256(convert_to(v_asalt || v_code, 'utf8')), 'hex') = v_ahash then
    update profiles set marina_access = true where id = v_uid;
    delete from work_unlock_attempts where user_id = v_uid;
    return 'ok_admin';
  end if;
  insert into work_unlock_attempts (user_id) values (v_uid);
  return 'wrong';
end;
$$;
revoke all on function public.unlock_work(text) from public, anon;
grant execute on function public.unlock_work(text) to authenticated;
