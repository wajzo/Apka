# Evidencia hodín

Jednoduchá webová aplikácia na sledovanie odpracovaného času a návštev pracovísk, s účtami pre členov a upomienkami. Backend: Supabase, frontend: jeden súbor `index.html` (vanilla JS).

## Čo už funguje

- Prihlásenie a vytvorenie účtu menom a 4-miestnym PIN-om (bez e-mailu)
- Stopky Štart/Stop s uložením času do cloudu (pracovisko Arkadyhof)
- Ručné zadanie času od–do (dátum, od, do, pauza) pri pracovisku s meraním času
- Odškrtnutie návštevy bez merania času (Objekt Keramik, Pekná cesta 3 a 5)
- Týždenná pripomienka, ak sa na pracovisko treba vrátiť
- Slovenské sviatky v kalendári (dni pracovného pokoja, pracovné dni s príplatkom, sviatky bez príplatku) a upozornenie, keď si vo sviatok pracoval
- Odstránenie záznamu v detaile dňa
- Pridanie záznamu na ľubovoľný deň priamo z kalendára (tlačidlo **Pridať záznam** v detaile dňa)
- Vlastné miesta každého používateľa: stačí vložiť odkaz (web firmy alebo mapa), názov a obrázok sa zistia automaticky a pred uložením sa dajú upraviť
- Inštalácia do telefónu (PWA): apka sa dá pridať na plochu ako bežná aplikácia, otvára sa na celú obrazovku a ikonu má vlastnú
- Fixné bočné menu vľavo (na mobile vysúvacie cez tlačidlo ☰). Prvá položka je **Záznam práce** (stopky, ručný čas, návštevy a kalendár). Pridanie ďalšej položky: pridaj objekt `{ id, label, icon }` do poľa `VIEWS` v `index.html` a do HTML sekciu `<section class="view" id="view-<id>" hidden>`. Menu, adresa `#<id>`, nadpis a zatváranie menu na mobile sa urobia samy.
- **Marína rozpis** (verejná sekcia): kalendár voľných dní, zákazník aj bez účtu vyberie termín a odošle rezerváciu (dátum, meno, kam pôjde, poznámka). Priamy odkaz: `…/Apka/#marina`, otvára sa bez prihlásenia a je aj na prihlasovacej obrazovke. Owner v tejto sekcii tlačidlom **Upraviť voľné dni** označuje voľné dni a rezervácie potvrdzuje alebo ruší. Rezervovaný deň zmizne z verejného kalendára a po zrušení sa uvoľní.
- Pravý panel: prehľad mesiaca (kde som bol, koľkokrát, koľko hodín) a kalendár s detailom dňa a možnosťou zmazať záznam

## Čo ešte chýba

- Formulár „Upomienky od iných" a zoznam úloh (databáza je pripravená v `setup.sql`)

## Spustenie

1. Vytvor projekt na supabase.com (región Frankfurt).
2. V *SQL Editor* spusti celý `setup.sql` (len raz).
3. *Authentication → Sign In / Providers → Email*: vypni **Confirm email**.
4. Účty si ľudia vytvoria sami v apke (**Nemáš účet? Vytvoriť účet**): meno a 4-miestny PIN. Profil sa vytvorí automaticky ako `member`. (Interne sa z mena vyrobí e-mail `meno@example.com` a heslo `Apka-` + PIN, nikto ich nezadáva.)
5. Seba urob hlavným používateľom: najprv sa zaregistruj v apke, potom v *SQL Editor* spusti `update profiles set role = 'owner' where full_name = 'Wwz';` (uprav meno). Owner musí byť presne jeden.
6. V `index.html` doplň `SUPABASE_URL` a `SUPABASE_KEY` (*Project Settings → API*, anon/publishable key).
7. Nasaď cez GitHub Pages: v repozitári *Settings → Pages*, vetva `main`, priečinok `/ (root)`. Adresa je `https://<používateľ>.github.io/<repozitár>/`. Pri inom hostingu (napr. Netlify Drop) nahraj **celý priečinok**, nielen `index.html`, inak nebude fungovať inštalácia do telefónu. Inštalácia vyžaduje https.

## Inštalácia do telefónu

Súbory `manifest.webmanifest`, `sw.js` a priečinok `icons/` robia z webu inštalovateľnú aplikáciu. Všetky odkazy sú relatívne, takže to funguje aj na adrese s podpriečinkom (`…github.io/Apka/`).

- **Android (Chrome):** v apke sa objaví lišta **Nainštalovať**, alebo menu ⋮ → *Inštalovať aplikáciu*.
- **iPhone (len Safari):** *Zdieľať* → *Pridať na plochu*. Lišta v apke ukáže tento návod.
- Service worker uloží vzhľad apky do pamäte, aby sa otvorila aj pri slabom signáli. Údaje (hodiny, kalendár) sa vždy načítavajú zo siete, bez internetu apka nezapíše nič. Po zmene súborov zvýš `CACHE` v `sw.js` (napr. `apka-v2`), ak by sa starý vzhľad držal v telefóne.

## Vlastné miesta (odkaz → názov a obrázok)

1. V Supabase → *SQL Editor* spusti raz `migrations/2026-10-27_personal_places.sql` (pridá stĺpce a pravidlá prístupu). Do tej doby apka funguje, len bez tlačidla **Pridať miesto**. Pri novej inštalácii je toto už súčasťou `setup.sql`.
2. Funkcia `supabase/functions/link-preview` (Edge Function) načíta stránku z odkazu a vráti názov a obrázok (`og:image`, inak ikona stránky). Nasadzuje sa v Supabase → *Edge Functions* alebo cez `supabase functions deploy link-preview`. Vyžaduje prihláseného používateľa a blokuje súkromné adresy (ochrana pred SSRF).
3. Miesta s `created_by = null` sú zdieľané a vidia ich všetci, miesta vytvorené v apke vidí len ich autor (a owner v databáze).

## Marína rozpis (databáza)

Spusti raz v *SQL Editor* `migrations/2026-10-28_marina_rozpis.sql` (pri novej inštalácii je v `setup.sql`, sekcia 10). Verejnosť nemá prístup k tabuľkám, len k dvom funkciám: `marina_open_days` (voľné dni) a `marina_book` (vytvorí rezerváciu a overí, že deň je voľný a nie je obsadený; max. 3 čakajúce rezervácie na meno). Voľné dni a rezervácie vidí a mení len owner. Kým migrácia nebeží, sekcia zobrazí upozornenie.

## Sviatky

Kalendár počíta slovenské sviatky sám (vrátane Veľkej noci). Pre rok 2026 platí výnimka: 8. máj a 15. september nie sú dňami pracovného pokoja, ale za prácu v tieto dni patrí príplatok. 1. september, 28. október a 17. november sú bez príplatku. V ďalších rokoch over aktuálne znenie zákona 241/1993 a Zákonníka práce a v prípade zmeny uprav funkciu `holidaysFor` v `index.html`. Informácia o príplatku je len orientačná.

## Bezpečnosť

- Anon kľúč smie byť v kóde viditeľný, dáta chránia pravidlá Row Level Security zo `setup.sql`. Nikdy sem nevkladaj `service_role` kľúč.
- 4-miestny PIN má len 10 000 kombinácií. Supabase obmedzuje počet pokusov o prihlásenie, ale PIN nie je silná ochrana. Hodí sa pre malú dôveryhodnú skupinu. Predpona `Apka-` je v kóde verejná, takže nezvyšuje bezpečnosť, len spĺňa minimálnu dĺžku hesla.
