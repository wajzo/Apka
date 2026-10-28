-- Predvolený kód pre Záznam práce je 101010.
-- Spusti raz v Supabase → SQL Editor. Zruší aj prípadný skôr nastavený vlastný kód, takže platí 101010.
-- (Vlastný kód nastavíš neskôr šablónou migrations/work_code.template.sql.)

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
