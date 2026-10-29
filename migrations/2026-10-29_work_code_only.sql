-- Kód pre Záznam práce (predvolený kód 101010). Samostatná migrácia: nepotrebuje žiadnu inú.
-- Spusti raz v Supabase → SQL Editor. Po zadaní kódu v Upraviť profil sa Záznam práce odomkne.

-- tabuľka nastavení (vlastný kód sa dá nastaviť šablónou migrations/work_code.template.sql)
create table if not exists public.marina_settings (
  key text primary key,
  value text not null
);
alter table public.marina_settings enable row level security;  -- bez politík: klient ju nevidí

alter table public.profiles add column if not exists work_access boolean not null default false;
update public.profiles set work_access = true where role = 'owner';

create or replace function public.has_work_access() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and (role = 'owner' or work_access));
$$;
revoke execute on function public.has_work_access() from public, anon;

-- záznamy hodín smie vidieť a upravovať len ten, kto má odomknutý Záznam práce
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

delete from public.marina_settings where key in ('work_code_salt', 'work_code_hash');

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
