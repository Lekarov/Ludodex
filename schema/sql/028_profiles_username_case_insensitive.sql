-- Ludodex Online — 028 : unicité du pseudo insensible à la casse
-- La contrainte `username text unique not null` de 002_profiles.sql est sensible à la casse :
-- "Doktor" et "doktor" pouvaient coexister. Décision prise avec l'utilisateur : deux pseudos qui
-- ne diffèrent que par la casse sont désormais refusés (évite la confusion/usurpation sur le
-- marché et le chat). L'ancienne contrainte reste en place (redondante mais inoffensive) ; cet
-- index unique sur lower(username) est la règle qui compte réellement désormais.

drop index if exists public.profiles_username_ci_key;
create unique index profiles_username_ci_key on public.profiles (lower(username));
