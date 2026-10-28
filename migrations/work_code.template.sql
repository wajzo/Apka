-- Šablóna: zmena kódu pre Záznam práce (bez nej platí predvolený kód 101010). NEVKLADAJ do repozitára s vyplneným kódom.
-- Nahraď __KOD__ (6 číslic) a __SOL__ (náhodný reťazec) a spusti v SQL Editor. Opätovné spustenie kód zmení
-- (už odomknuté účty zostanú odomknuté; ak chceš niekomu prístup zrušiť: update profiles set work_access = false where full_name = '…';).
insert into public.marina_settings (key, value) values
  ('work_code_salt', '__SOL__'),
  ('work_code_hash', encode(sha256(convert_to('__SOL__' || '__KOD__', 'utf8')), 'hex'))
on conflict (key) do update set value = excluded.value;
