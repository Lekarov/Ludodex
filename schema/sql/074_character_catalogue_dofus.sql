-- Ludodex Online — 074 : ouvre character_type à Dofus (bestiaire), 5 132 fiches : monstres
-- français de l'API publique et gratuite api.dofusdb.fr (aucune clé requise). PNJ volontairement
-- exclus — l'API n'expose qu'un code d'apparence ("look") non rendu en image, aucun service
-- public trouvé pour le transformer en PNG (voir data/volumes/dofus_2026/ et l'en-tête de
-- generate_character_catalogue.js pour le détail de la recherche).
-- Ajoute 'monster', 'miniboss', 'boss' à la contrainte de 045/046 (`drop`/`add` = idempotent).

alter table public.character_catalogue drop constraint if exists character_catalogue_character_type_check;
alter table public.character_catalogue add constraint character_catalogue_character_type_check
  check (character_type in ('villager', 'special', 'standard', 'legendary', 'mythical', 'mega', 'gmax', 'regional', 'skin', 'monster', 'miniboss', 'boss'));
