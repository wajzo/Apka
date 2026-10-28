-- Profil Maríny + okamžité upozornenia na nové rezervácie.
-- Spusti raz v Supabase → SQL Editor (po migrácii 2026-10-28_marina_rozpis.sql).
-- Samotný účet Maríny a tajné hodnoty (kľúč na prihlásenie, téma upozornení) sa nevytvárajú tu,
-- ale v súbore podľa migrations/marina_account.template.sql (tajné hodnoty nepatria do verejného repozitára).

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
