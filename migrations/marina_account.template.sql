-- Šablóna: účet Maríny + tajné nastavenia. NEVKLADAJ do repozitára s vyplnenými hodnotami.
-- Nahraď __KLUC__ (náhodný reťazec z písmen a čísel, aspoň 24 znakov), __TEMA__ (náhodná téma pre ntfy)
-- a __URL__ (adresa apky, napr. https://wajzo.github.io/Apka/#marina), potom spusti v SQL Editor.
-- Marína sa prihlási odkazom  <adresa apky>#k=__KLUC__  (stačí ho raz otvoriť v jej telefóne, prihlásenie sa zapamätá).

do $$
declare uid uuid;
begin
  select id into uid from auth.users where email = 'marina@example.com';
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', 'marina@example.com',
      extensions.crypt('Marina-__KLUC__', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{"full_name":"Marína"}', now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', 'marina@example.com'), 'email', now(), now(), now());
  else
    update auth.users set encrypted_password = extensions.crypt('Marina-__KLUC__', extensions.gen_salt('bf')) where id = uid;
  end if;
  insert into public.profiles (id, full_name, role) values (uid, 'Marína', 'marina')
    on conflict (id) do update set full_name = 'Marína', role = 'marina';
end $$;

insert into public.marina_settings (key, value) values ('ntfy_topic', '__TEMA__'), ('app_url', '__URL__')
  on conflict (key) do update set value = excluded.value;
