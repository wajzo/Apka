-- Ručne potvrdzovaná platba: bez automatickej platobnej brány a bez tlačidla „Zaplatil som“.
-- Zákazník po formulári dostane QR kód na úhradu 2,50 € a rezervácia je v stave „Čaká na platbu“ (drží deň 24 hodín).
-- Oficiálne zaevidovaná (stav 'new') je až po tom, čo Marína / správca v apke potvrdí prijatie platby.
-- Spusti raz v Supabase → SQL Editor po migrácii 2026-10-29_marina_all_days_admin_code.sql.

-- 1) Verejné: voľné dni = všetky dni od dneška okrem zablokovaných a už rezervovaných
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
        and not (b.status = 'pending_payment' and b.created_at < now() - interval '24 hours'))
  order by 1;
$$;

-- 2) Vytvorenie rezervácie: deň nesmie byť zablokovaný (namiesto zoznamu voľných dní)
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
    where day = p_day and status = 'pending_payment' and created_at < now() - interval '24 hours';
  -- ochrana pred blokovaním termínov nezaplatenými rezerváciami
  if (select count(*) from marina_bookings where status = 'pending_payment' and created_at > now() - interval '24 hours') >= 30 then
    raise exception 'busy';
  end if;
  if (select count(*) from marina_bookings where status in ('pending_payment', 'new') and lower(customer_name) = lower(btrim(p_name))) >= 3 then
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

-- 3) Upozornenie pre Marínu pri založení rezervácie: čaká na platbu, treba overiť prevod v banke.
-- Rezervácia je oficiálne zaevidovaná (stav 'new') až po potvrdení platby v apke.
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
        || E'\nDátum: ' || to_char(new.day, 'DD.MM.YYYY')
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

drop trigger if exists marina_booking_notify on public.marina_bookings;
create trigger marina_booking_notify
  after insert on public.marina_bookings
  for each row execute function public.marina_notify();
