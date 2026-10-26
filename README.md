# Evidencia hodín

Jednoduchá webová aplikácia na sledovanie odpracovaného času a návštev pracovísk, s účtami pre členov a upomienkami. Backend: Supabase, frontend: jeden súbor `index.html` (vanilla JS).

## Čo už funguje

- Prihlásenie menom a 4-miestnym PIN-om (bez e-mailu)
- Stopky Štart/Stop s uložením času do cloudu (pracovisko Arkadyhof)
- Odškrtnutie návštevy bez merania času (Objekt Keramik, Pekná cesta 3 a 5)
- Týždenná pripomienka, ak sa na pracovisko treba vrátiť

## Čo ešte chýba

- Kalendárový prehľad odpracovaných dní a hodín
- Formulár „Upomienky od iných" a zoznam úloh (databáza je pripravená v `setup.sql`)

## Spustenie

1. Vytvor projekt na supabase.com (región Frankfurt).
2. V *SQL Editor* spusti celý `setup.sql` (len raz).
3. *Authentication → Sign In / Providers → Email*: vypni **Confirm email**.
4. *Authentication → Users → Add user → Create new user*, zaškrtni **Auto Confirm User**:
   - **E-mail:** meno malými písmenami, bez diakritiky, medzera = bodka, koncovka `@example.com` (Wwz → `wwz@example.com`, Ján Novák → `jan.novak@example.com`). Je len interný, nikto ho nezadáva ani nedostáva poštu.
   - **Heslo:** `Apka-` + PIN. Pre PIN `1234` zadaj `Apka-1234`. Predpona je v apke doplnená automaticky, ľudia zadávajú len meno a 4 číslice.
5. Pre každého spusti riadok `insert into profiles …` z konca `setup.sql` (ty ako `owner`, ostatní `member`).
6. V `index.html` doplň `SUPABASE_URL` a `SUPABASE_KEY` (*Project Settings → API*, anon/publishable key).
7. Nasaď napr. cez app.netlify.com/drop alebo GitHub Pages.

## Bezpečnosť

- Anon kľúč smie byť v kóde viditeľný, dáta chránia pravidlá Row Level Security zo `setup.sql`. Nikdy sem nevkladaj `service_role` kľúč.
- 4-miestny PIN má len 10 000 kombinácií. Supabase obmedzuje počet pokusov o prihlásenie, ale PIN nie je silná ochrana. Hodí sa pre malú dôveryhodnú skupinu. Predpona `Apka-` je v kóde verejná, takže nezvyšuje bezpečnosť, len spĺňa minimálnu dĺžku hesla.
