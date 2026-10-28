-- Marína rozpis: verejný kalendár voľných dní a rezervácie od zákazníkov.
-- Spusti raz v Supabase → SQL Editor. Pri novej inštalácii je toto už súčasťou setup.sql (sekcia 10).
--
-- Princíp:
--  * voľné dni nastavuje len owner (tabuľka marina_free_days),
--  * nezaregistrovaný zákazník nemá prístup k tabuľkám, len ku dvom funkciám:
--      marina_open_days(od, do)  -> zoznam voľných dní (bez už rezervovaných)
--      marina_book(...)          -> vytvorí rezerváciu (overí, že deň je voľný)
--  * rezervácie vidí a spravuje len owner.

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
