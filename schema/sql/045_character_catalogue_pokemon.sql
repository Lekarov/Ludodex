-- Ludodex Online — 045 : ouvre character_type à un deuxième franchise (Pokémon, 1 347 fiches :
-- formes standards + Méga-évolutions + Gigamax + formes régionales Alola/Galar/Hisui/Paldéa +
-- légendaires/mythiques, via l'export CSV public du dépôt GitHub PokeAPI/pokeapi, noms en
-- français). La contrainte de 044 ('villager'/'special') était propre à Animal Crossing —
-- generate_character_catalogue.js utilise maintenant des valeurs plus descriptives par
-- franchise (standard, legendary, mythical, mega, gmax, regional pour Pokémon), donc on l'élargit
-- au lieu de la garder figée à un seul jeu.
--
-- CORRIGÉ le 28/09/2026 (bug découvert en rejouant la migration) : la liste ci-dessous inclut
-- directement 'skin' (n'apparaît normalement qu'en 046, League of Legends) pour que ce fichier
-- reste rejouable même quand la table contient déjà des personnages League of Legends — sinon
-- l'ADD CONSTRAINT échoue en validant des lignes 'skin' déjà en base avec une liste trop étroite.
-- `drop constraint if exists` évite aussi l'échec si 045 a déjà tourné avant 046 dans le même lot.

alter table public.character_catalogue drop constraint if exists character_catalogue_character_type_check;
alter table public.character_catalogue add constraint character_catalogue_character_type_check
  check (character_type in ('villager', 'special', 'standard', 'legendary', 'mythical', 'mega', 'gmax', 'regional', 'skin'));
