-- Marína rozpis po hodinách: každý deň 12:00–22:00 (10 jednohodinových termínov), jeden deň si môže objednať viac ľudí.
-- Spusti raz v Supabase → SQL Editor po migrácii 2026-10-31_marina_manual_payment.sql.

alter table public.marina_bookings add column if not exists hour smallint;
update public.marina_bookings set hour = 12 where hour is null;
alter table public.marina_bookings alter column hour set not null;
alter table public.marina_bookings drop constraint if exists marina_bookings_hour_check;
alter table public.marina_bookings add constraint marina_bookings_hour_check check (hour between 12 and 21);

-- namiesto „jedna rezervácia na deň“ platí „jedna rezervácia na hodinu“
drop index if exists public.marina_bookings_one_per_day;
create unique index if not exists marina_bookings_one_per_slot
  on public.marina_bookings (day, hour) where status <> 'cancelled';

-- Verejné: dni, v ktorých je ešte aspoň jedna voľná hodina (nezablokované, nevypredané)
create or replace function public.marina_open_days(p_from date, p_to date)
returns setof date
language sql stable security definer set search_path = public
as $$
  with t as (select (now() at time zone 'Europe/Bratislava')::date as d,
                    extract(hour from now() at time zone 'Europe/Bratislava')::int as h)
  select g::date
  from t, generate_series(greatest(p_from, t.d), least(p_to, t.d + 365), interval '1 day') g
  where not exists (select 1 from marina_blocked_days k where k.day = g::date)
    and exists (
      select 1 from generate_series(12, 21) hh
      where (g::date > t.d or hh > t.h)
        and not exists (
          select 1 from marina_bookings b
          where b.day = g::date and b.hour = hh and b.status <> 'cancelled'
            and not (b.status = 'pending_payment' and b.created_at < now() - interval '24 hours')))
  order by 1;
$$;

-- Verejné: obsadené hodiny vybraného dňa a meno toho, kto ich rezervoval (bez cieľa cesty a poznámky)
create or replace function public.marina_day_slots(p_day date)
returns table (hour int, customer_name text, state text)
language sql stable security definer set search_path = public
as $$
  select b.hour::int, b.customer_name, case when b.status = 'pending_payment' then 'pending' else 'booked' end
  from marina_bookings b
  where b.day = p_day and b.status <> 'cancelled'
    and not (b.status = 'pending_payment' and b.created_at < now() - interval '24 hours')
  order by b.hour;
$$;
revoke all on function public.marina_day_slots(date) from public;
grant execute on function public.marina_day_slots(date) to anon, authenticated;

-- Založenie rezervácie na konkrétnu hodinu (len server)
drop function if exists public.marina_create_pending(date, text, text, text);
create or replace function public.marina_create_pending(p_day date, p_hour int, p_name text, p_destination text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_today date := (now() at time zone 'Europe/Bratislava')::date;
  v_hour int := extract(hour from now() at time zone 'Europe/Bratislava')::int;
begin
  if p_day is null or p_day < v_today or p_day > v_today + 365 then raise exception 'bad_day'; end if;
  if p_hour is null or p_hour not between 12 and 21 or (p_day = v_today and p_hour <= v_hour) then raise exception 'bad_hour'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 80
     or char_length(btrim(coalesce(p_destination, ''))) not between 1 and 120
     or char_length(coalesce(p_note, '')) > 1000 then
    raise exception 'bad_input';
  end if;
  if exists (select 1 from marina_blocked_days where day = p_day) then raise exception 'day_not_free'; end if;
  update marina_bookings set status = 'cancelled'
    where day = p_day and hour = p_hour and status = 'pending_payment' and created_at < now() - interval '24 hours';
  if (select count(*) from marina_bookings where status = 'pending_payment' and created_at > now() - interval '24 hours') >= 30 then
    raise exception 'busy';
  end if;
  if (select count(*) from marina_bookings where status in ('pending_payment', 'new') and lower(customer_name) = lower(btrim(p_name))) >= 5 then
    raise exception 'too_many';
  end if;
  begin
    insert into marina_bookings (day, hour, customer_name, destination, note, status, amount_cents)
    values (p_day, p_hour, btrim(p_name), btrim(p_destination), nullif(btrim(coalesce(p_note, '')), ''), 'pending_payment', 250)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;
  return v_id;
end;
$$;
revoke all on function public.marina_create_pending(date, int, text, text, text) from public, anon, authenticated;
grant execute on function public.marina_create_pending(date, int, text, text, text) to service_role;

-- Upozornenie pre Marínu: pribudol čas
create or replace function public.marina_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_topic text := (select value from marina_settings where key = 'ntfy_topic');
  v_url   text := (select value from marina_settings where key = 'app_url');
  v_msg   text;
begin
  if new.status <> 'pending_payment' then return new; end if;
  if v_topic is null then return new; end if;
  v_msg := 'Čaká na platbu 2,50 €. Over prevod v banke, správa: R-' || upper(left(replace(new.id::text, '-', ''), 6))
        || E'\nDátum: ' || to_char(new.day, 'DD.MM.YYYY') || ' ' || new.hour || ':00–' || (new.hour + 1) || ':00'
        || E'\nMeno: ' || new.customer_name
        || E'\nKam: ' || new.destination
        || E'\nPoznámka: ' || coalesce(new.note, '–');
  begin
    perform net.http_post(
      url := 'https://ntfy.sh',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_strip_nulls(jsonb_build_object(
        'topic', v_topic, 'title', 'Rezervácia čaká na platbu', 'message', v_msg,
        'priority', 4, 'tags', jsonb_build_array('calendar'), 'click', v_url))
    );
  exception when others then
    null;
  end;
  return new;
end;
$$;
revoke execute on function public.marina_notify() from public, anon, authenticated;
