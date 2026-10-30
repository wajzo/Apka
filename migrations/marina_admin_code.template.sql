-- Šablóna: druhý kód (správa rezervácií). NEVKLADAJ do repozitára s vyplneným kódom.
-- Nahraď __KOD__ (6 číslic) a __SOL__ (náhodný reťazec) a spusti v SQL Editor. Opätovné spustenie kód zmení.
-- Prístup odoberieš: update profiles set marina_access = false where full_name = '…';
insert into public.marina_settings (key, value) values
  ('marina_admin_salt', '__SOL__'),
  ('marina_admin_hash', encode(sha256(convert_to('__SOL__' || '__KOD__', 'utf8')), 'hex'))
on conflict (key) do update set value = excluded.value;
