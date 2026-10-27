-- Vlastné miesta používateľov (odkaz + obrázok).
-- Spusti raz v Supabase → SQL Editor. Miesta s created_by = null sú zdieľané (vidia ich všetci).

alter table public.workplaces
  add column if not exists url text,
  add column if not exists image_url text,
  add column if not exists created_by uuid references public.profiles(id);

alter table public.workplaces
  add constraint workplaces_name_len check (char_length(name) between 1 and 120),
  add constraint workplaces_url_http check (url is null or url ~* '^https?://'),
  add constraint workplaces_image_http check (image_url is null or image_url ~* '^https?://'),
  add constraint workplaces_visit_days check (visit_every_days is null or visit_every_days between 1 and 365);

create index if not exists workplaces_created_by_idx on public.workplaces (created_by);

drop policy if exists workplaces_read on public.workplaces;
drop policy if exists workplaces_owner_write on public.workplaces;

-- vidím zdieľané a svoje; owner vidí všetky
create policy workplaces_read on public.workplaces
  for select to authenticated
  using (created_by is null or created_by = (select auth.uid()) or public.is_owner());

-- vytváram len vlastné miesta; zdieľané (created_by null) smie vytvoriť len owner
create policy workplaces_insert on public.workplaces
  for insert to authenticated
  with check (created_by = (select auth.uid()) or public.is_owner());

-- upravujem svoje; owner všetky
create policy workplaces_update on public.workplaces
  for update to authenticated
  using (created_by = (select auth.uid()) or public.is_owner())
  with check (created_by = (select auth.uid()) or public.is_owner());

create policy workplaces_delete on public.workplaces
  for delete to authenticated
  using (created_by = (select auth.uid()) or public.is_owner());
