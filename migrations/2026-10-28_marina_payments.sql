-- Platba 2,50 € pred rezerváciou (Marína rozpis).
-- Spusti raz v Supabase → SQL Editor po migráciách marina_rozpis a marina_profile.
--
-- Princíp: rezerváciu už nemožno vytvoriť priamo z prehliadača. Edge funkcia marina-checkout (so service_role kľúčom)
-- založí rezerváciu v stave 'pending_payment' (drží deň 30 minút) a otvorí platbu. Až po potvrdení platby
-- (webhook Stripe, alebo simulácia) sa stav zmení na 'new' a Maríne príde upozornenie.

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
