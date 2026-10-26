# Evidencia hodín

Jednoduchá webová aplikácia na sledovanie odpracovaného času a návštev pracovísk, s účtami pre členov a upomienkami. Backend: Supabase, frontend: jeden súbor `index.html` (vanilla JS).

## Čo už funguje

- Prihlásenie menom a heslom/PIN-om
- Stopky Štart/Stop s uložením času do cloudu (pracovisko Arkadyhof)
- Odškrtnutie návštevy bez merania času (Objekt Keramik, Pekná cesta 3 a 5)
- Týždenná pripomienka, ak sa na pracovisko treba vrátiť

## Čo ešte chýba

- Kalendárový prehľad odpracovaných dní a hodín
- Formulár „Upomienky od iných" a zoznam úloh (databáza je pripravená v `setup.sql`)

## Spustenie

1. Vytvor projekt na supabase.com.
2. V *SQL Editor* spusti celý `setup.sql`.
3. *Authentication → Providers → Email*: vypni **Confirm email**.
4. *Authentication → Users → Add user*: e-mail v tvare `meno@example.com` (bez diakritiky), heslo/PIN, zaškrtni **Auto Confirm User**. Potom pre každého spusti riadok `insert into profiles …` z konca `setup.sql` (ty ako `owner`, ostatní `member`).
5. V `index.html` doplň `SUPABASE_URL` a `SUPABASE_KEY` (*Project Settings → API*, anon/publishable key).
6. Nasaď napr. cez app.netlify.com/drop alebo GitHub Pages.

Anon kľúč smie byť v kóde viditeľný, dáta chránia pravidlá Row Level Security zo `setup.sql`. Nikdy sem nevkladaj `service_role` kľúč.
