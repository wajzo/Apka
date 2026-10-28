-- Rola Admin: po prihlásení vidí všetko (hodiny všetkých, všetkých používateľov, všetky upomienky, všetky rezervácie Marína rozpis).
-- Spusti raz v Supabase → SQL Editor (po ostatných migráciách). Potom urob zo seba admina:
--   update profiles set role = 'admin' where full_name = 'Wwz';   -- uprav meno

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner', 'member', 'marina', 'admin'));

-- is_owner() platí aj pre admina, takže admin dedí všetky práva ownera
-- (čítanie hodín všetkých, správa profilov, rozpis a rezervácie Marína rozpis, zdieľané miesta)
create or replace function public.is_owner() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('owner', 'admin'));
$$;

-- Záznam práce má admin vždy odomknutý
create or replace function public.has_work_access() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and (role in ('owner', 'admin') or work_access));
$$;

-- Upomienky: admin vidí všetky (člen svoje, adresát tie pre neho)
drop policy if exists rem_read on public.reminders;
create policy rem_read on public.reminders
  for select to authenticated
  using (created_by = (select auth.uid()) or assigned_to = (select auth.uid()) or public.is_owner());

-- Upomienky sa priradia ownerovi, a ak owner nie je (iba admin), adminovi
create or replace function public.set_reminder_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.created_by  := auth.uid();
  new.assigned_to := (select id from profiles where role in ('owner', 'admin') order by (role = 'owner') desc, created_at limit 1);
  new.status      := 'open';
  return new;
end;
$$;
revoke execute on function public.set_reminder_owner() from public, anon, authenticated;
