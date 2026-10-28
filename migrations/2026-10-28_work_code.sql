-- Záznam práce je chránený vlastným 6-miestnym kódom, ktorý nemá každý nový účet.
-- Spusti raz v Supabase → SQL Editor. Samotný kód nastav šablónou migrations/work_code.template.sql (kód nepatrí do repozitára).
--
-- Používateľ si sekciu odomkne v apke: Upraviť profil → Kód pre Záznam práce. Odomknutie overuje databáza
-- (po 5 nesprávnych pokusoch za hodinu sa zamkne) a prístup k záznamom hodín vynucuje RLS, nielen vzhľad apky.

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
