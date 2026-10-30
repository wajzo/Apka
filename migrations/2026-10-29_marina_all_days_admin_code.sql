-- Marína rozpis: všetky dni sú predvolene voľné, Marína si môže dni zablokovať, rezervácie prijíma alebo odmieta.
-- Druhý kód v poli Upraviť profil odomkne správu rezervácií (prijať/odmietnuť) aj ďalšiemu účtu.
-- Spusti raz v Supabase → SQL Editor (po migráciách marina_rozpis, marina_profile, payments a work_code).
-- Samotný druhý kód sa nastavuje šablónou migrations/marina_admin_code.template.sql (kód nepatrí do repozitára).

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
