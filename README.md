# Evidencia hodín

Jednoduchá webová aplikácia na sledovanie odpracovaného času a návštev pracovísk, s účtami pre členov a upomienkami. Backend: Supabase, frontend: jeden súbor `index.html` (vanilla JS).

## Čo už funguje

- Prihlásenie a vytvorenie účtu menom a 4-miestnym PIN-om (bez e-mailu)
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
4. Účty si ľudia vytvoria sami v apke (**Nemáš účet? Vytvoriť účet**): meno a 4-miestny PIN. Profil sa vytvorí automaticky ako `member`. (Interne sa z mena vyrobí e-mail `meno@example.com` a heslo `Apka-` + PIN, nikto ich nezadáva.)
5. Seba urob hlavným používateľom: najprv sa zaregistruj v apke, potom v *SQL Editor* spusti `update profiles set role = 'owner' where full_name = 'Wwz';` (uprav meno). Owner musí byť presne jeden.
6. V `index.html` doplň `SUPABASE_URL` a `SUPABASE_KEY` (*Project Settings → API*, anon/publishable key).
7. Nasaď napr. cez app.netlify.com/drop alebo GitHub Pages.

## Bezpečnosť

- Anon kľúč smie byť v kóde viditeľný, dáta chránia pravidlá Row Level Security zo `setup.sql`. Nikdy sem nevkladaj `service_role` kľúč.
- 4-miestny PIN má len 10 000 kombinácií. Supabase obmedzuje počet pokusov o prihlásenie, ale PIN nie je silná ochrana. Hodí sa pre malú dôveryhodnú skupinu. Predpona `Apka-` je v kóde verejná, takže nezvyšuje bezpečnosť, len spĺňa minimálnu dĺžku hesla.
