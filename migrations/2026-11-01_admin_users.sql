-- Admin: po zadaní druhého kódu (správa rezervácií) sa stav profilu zmení na „admin“
-- a účet uvidí zoznam všetkých registrovaných používateľov (sekcia Používatelia).
-- Spusti raz v Supabase → SQL Editor po migrácii 2026-10-29_marina_all_days_admin_code.sql.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner', 'member', 'marina', 'admin'));

-- už odomknuté účty sa prepnú na admin (hlavný používateľ a Marína zostávajú, ako sú)
update public.profiles set role = 'admin' where marina_access and role = 'member';

-- Kto je správca: hlavný používateľ, admin alebo účet s odomknutou správou rezervácií
create or replace function public.is_admin_user() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and (role in ('owner', 'admin') or marina_access));
$$;
revoke execute on function public.is_admin_user() from public, anon;
grant execute on function public.is_admin_user() to authenticated;

-- Zoznam všetkých účtov (bez e-mailov a PIN-ov)
create or replace function public.list_users()
returns table (id uuid, full_name text, role text, work_access boolean, marina_access boolean, created_at timestamptz)
language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_admin_user() then raise exception 'forbidden'; end if;
  return query select p.id, p.full_name, p.role, p.work_access, p.marina_access, p.created_at
               from profiles p order by p.created_at desc;
end;
$$;
revoke all on function public.list_users() from public, anon;
grant execute on function public.list_users() to authenticated;

-- Odomknutie kódom: prvý kód Záznam práce, druhý kód admin (správa rezervácií + stav profilu „admin“)
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
    update profiles set marina_access = true,
                        role = case when role = 'member' then 'admin' else role end
      where id = v_uid;
    delete from work_unlock_attempts where user_id = v_uid;
    return 'ok_admin';
  end if;
  insert into work_unlock_attempts (user_id) values (v_uid);
  return 'wrong';
end;
$$;
revoke all on function public.unlock_work(text) from public, anon;
grant execute on function public.unlock_work(text) to authenticated;
