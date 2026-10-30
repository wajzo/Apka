# Evidencia hodín

Jednoduchá webová aplikácia na sledovanie odpracovaného času a návštev pracovísk, s účtami pre členov a upomienkami. Backend: Supabase, frontend: jeden súbor `index.html` (vanilla JS).

## Čo už funguje

- Prihlásenie a vytvorenie účtu menom a 4-miestnym PIN-om (bez e-mailu)
- Stopky Štart/Stop s uložením času do cloudu (pracovisko Arkadyhof)
- Ručné zadanie času od–do (dátum, od, do, pauza) pri pracovisku s meraním času
- Odškrtnutie návštevy bez merania času (Objekt Keramik, Pekná cesta 3 a 5)
- Týždenná pripomienka: Objekt Keramik a Pekná cesta treba navštíviť raz za kalendárny týždeň (pondelok až nedeľa), nie každých 7 dní. Kým sa tento týždeň neodškrtne, hore sa ukazuje upozornenie s počtom dní do nedele (od štvrtka červené) a apka môže raz denne poslať aj systémovú notifikáciu. Iný interval ako 7 dní funguje ako „po N dňoch od poslednej návštevy“
- Slovenské sviatky v kalendári (dni pracovného pokoja, pracovné dni s príplatkom, sviatky bez príplatku) a upozornenie, keď si vo sviatok pracoval
- Odstránenie záznamu v detaile dňa
- Pridanie záznamu na ľubovoľný deň priamo z kalendára (tlačidlo **Pridať záznam** v detaile dňa)
- Vlastné miesta každého používateľa: stačí vložiť odkaz (web firmy alebo mapa), názov a obrázok sa zistia automaticky a pred uložením sa dajú upraviť
- Inštalácia do telefónu (PWA): apka sa dá pridať na plochu ako bežná aplikácia, otvára sa na celú obrazovku a ikonu má vlastnú
- Fixné bočné menu vľavo (na mobile vysúvacie cez tlačidlo ☰). Prvá položka je **Záznam práce** (stopky, ručný čas, návštevy a kalendár). Pridanie ďalšej položky: pridaj objekt `{ id, label, icon }` do poľa `VIEWS` v `index.html` a do HTML sekciu `<section class="view" id="view-<id>" hidden>`. Menu, adresa `#<id>`, nadpis a zatváranie menu na mobile sa urobia samy.
- **Marína rozpis** (verejná sekcia): kalendár voľných dní, zákazník aj bez účtu vyberie termín a odošle rezerváciu (dátum, meno, kam pôjde, poznámka). Priamy odkaz: `…/Apka/#marina`, otvára sa bez prihlásenia a je aj na prihlasovacej obrazovke. **Všetky dni od dneška sú predvolene voľné**; Marína (owner) tlačidlom **Upraviť dostupnosť dní** jednotlivé dni zablokuje alebo opäť uvoľní. Každú zaplatenú rezerváciu **prijme** alebo **odmietne** (prípadne neskôr zruší). Rezervovaný deň zmizne z verejného kalendára a po zrušení sa uvoľní.
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

## Profil Maríny a upozornenia na rezervácie

- Marína má vlastnú rolu `marina` (pevné meno **Marína**): vidí len *Marína rozpis*, kde spravuje voľné dni a rezervácie. Hodiny ostatných nevidí.
- Prihlásenie: meno **Marína** a 4-miestny PIN, ako ostatní. PIN sa nastavuje v SQL zo šablóny (nie je v repozitári). Pozor: 4-miestny PIN sa dá odhadnúť a Marína vidí mená a ciele zákazníkov, preto ho nezdieľaj.
- Nastavenie: spusti `migrations/2026-10-28_marina_profile.sql` (pri novej inštalácii je v `setup.sql`, sekcia 11), potom `migrations/marina_account.template.sql` s vyplnenými hodnotami `__PIN__`, `__TEMA__`, `__URL__` (vyplnenú verziu nikam nenahrávaj).
- **Upozornenia:** po každej novej rezervácii databáza (trigger + `pg_net`) pošle push cez [ntfy.sh](https://ntfy.sh) na tajnú tému: dátum, meno, kam, poznámka. Marína si v telefóne nainštaluje apku *ntfy* a odoberá tému z nastavení. Kto tému pozná, vie upozornenia čítať, preto je náhodná a uložená len v tabuľke `marina_settings` (klient ju nevidí). Ak je apka otvorená, príde aj okamžité upozornenie priamo v nej (tlačidlo **Upozornenia** zapne systémové).

## Platba 2,50 € pred rezerváciou

Rezervácia v *Marína rozpis* sa vytvorí a odošle Maríne až po úspešnom zaplatení 2,50 €. Z prehliadača sa rezervovať nedá (verejná funkcia `marina_book` je zrušená), rezerváciu zakladá len Edge funkcia `marina-checkout` so service_role kľúčom, suma je určená na serveri.

Tok: formulár → `marina-checkout` založí rezerváciu v stave `pending_payment` (drží deň 30 minút) → platba → po potvrdení platby sa stav zmení na `new` a spustí sa upozornenie pre Marínu (ntfy + Realtime). Zrušená alebo nezaplatená rezervácia deň uvoľní.

Nastavenie:
1. Spusti `migrations/2026-10-28_marina_payments.sql` (pri novej inštalácii je v `setup.sql`, sekcia 12).
2. Nasaď funkcie `marina-checkout` a `stripe-webhook` (obe s `verify_jwt = false`, pozri `supabase/config.toml`): `supabase functions deploy marina-checkout stripe-webhook`.
3. *Edge Functions → Secrets*: `PAYMENT_MODE` (`qr` = platba QR kódom PAYME, `simulation` na skúšanie bez peňazí alebo `stripe`), `APP_URL` (napr. `https://wajzo.github.io/Apka/`) a pre Stripe `STRIPE_SECRET_KEY` a `STRIPE_WEBHOOK_SECRET`. Kým `PAYMENT_MODE` nie je nastavený, platby sa odmietajú.
4. Stripe → Developers → Webhooks: adresa `<SUPABASE_URL>/functions/v1/stripe-webhook`, udalosti `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.expired`.
5. Najprv vyskúšaj `simulation` (v apke sa ukáže skúšobný platobný dialóg), potom prepni na `stripe` s testovacím kľúčom `sk_test_…` a kartou 4242 4242 4242 4242.

**Režim `qr`:** v dialógu platby sa ukáže QR kód (`icons/payme-qr.png`, pevná suma 2,50 €) a odkaz do bankovej aplikácie so správou `R-XXXXXX` (kód rezervácie). Banka nevie platbu automaticky spárovať s rezerváciou, preto zákazník klikne „Zaplatil som“, rezervácia sa odošle Maríne s označením „Over platbu v banke“ a Marína ju po overení v banke potvrdí (alebo zruší). Nepotrebuje Stripe ani kľúče, stačí `PAYMENT_MODE=qr`. QR kód obsahuje IBAN, v repozitári je teda viditeľný.

Údaje o karte spracúva hosťovaná stránka Stripe, do apky ani databázy sa nedostanú. Ak Marína rezerváciu zruší, peniaze sa automaticky nevracajú (vrátenie urob v Stripe). Ak zákazník zaplatí po vypršaní držania a deň medzitým obsadil niekto iný, webhook to zapíše do logu funkcie a platbu treba vrátiť ručne.

## Kód pre Záznam práce a úprava profilu

Záznam práce je chránený vlastným 6-miestnym kódom, ktorý nedostane každý, kto si vytvorí účet. Nový účet vidí len *Marína rozpis*. Sekciu si odomkne v apke cez **Upraviť profil** zadaním kódu. Hlavný používateľ (owner) má prístup vždy.

Ochranu vynucuje databáza (RLS na `time_entries`), nie len vzhľad apky. Odomknutie overuje funkcia `unlock_work`, po 5 nesprávnych pokusoch za hodinu sa zamkne. Účty bez kódu nemôžu záznamy ani čítať, ani zapisovať.

Rýchle nastavenie len kódu (bez ostatných migrácií): spusti samostatný `migrations/2026-10-29_work_code_only.sql`. Úplné nastavenie: `migrations/2026-10-28_work_code.sql` a potom `migrations/2026-10-29_work_code_default.sql` (pri novej inštalácii je to v `setup.sql`, sekcie 13 a 15). **Predvolený kód je 101010.** Vlastný kód nastavíš šablónou `migrations/work_code.template.sql` (`__KOD__`, `__SOL__`; vyplnenú verziu nikam nenahrávaj). Už odomknuté účty zostanú odomknuté, prístup odoberieš: `update profiles set work_access = false where full_name = '…';`

## Sviatky

Kalendár počíta slovenské sviatky sám (vrátane Veľkej noci). Pre rok 2026 platí výnimka: 8. máj a 15. september nie sú dňami pracovného pokoja, ale za prácu v tieto dni patrí príplatok. 1. september, 28. október a 17. november sú bez príplatku. V ďalších rokoch over aktuálne znenie zákona 241/1993 a Zákonníka práce a v prípade zmeny uprav funkciu `holidaysFor` v `index.html`. Informácia o príplatku je len orientačná.

## Bezpečnosť

- Anon kľúč smie byť v kóde viditeľný, dáta chránia pravidlá Row Level Security zo `setup.sql`. Nikdy sem nevkladaj `service_role` kľúč.
- 4-miestny PIN má len 10 000 kombinácií. Supabase obmedzuje počet pokusov o prihlásenie, ale PIN nie je silná ochrana. Hodí sa pre malú dôveryhodnú skupinu. Predpona `Apka-` je v kóde verejná, takže nezvyšuje bezpečnosť, len spĺňa minimálnu dĺžku hesla.

## Správa rezervácií druhým kódom

V *Upraviť profil* je jedno políčko na kód: prvý kód (predvolene 101010) odomkne *Záznam práce*, **druhý kód odomkne správu rezervácií** v *Marína rozpis* (Prijať / Odmietnuť / blokovať dni) pre daný účet. Migrácia: `migrations/2026-10-29_marina_all_days_admin_code.sql` (pri novej inštalácii `setup.sql`, sekcia 16). Samotný kód nastavíš šablónou `migrations/marina_admin_code.template.sql` (`__KOD__`, `__SOL__`; vyplnenú verziu nikam nenahrávaj). Prístup odoberieš: `update profiles set marina_access = false where full_name = '…';`. Po 5 nesprávnych pokusoch za hodinu sa pole zamkne.
