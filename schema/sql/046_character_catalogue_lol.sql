-- Ludodex Online — 046 : ouvre character_type à un troisième franchise (League of Legends,
-- 2 122 fiches : 173 champions + leurs skins non-chroma, via l'API officielle et gratuite Riot
-- Data Dragon, noms en français). Ajoute la valeur 'skin' à la contrainte de 045.
--
-- 045 a été corrigé le 28/09/2026 pour inclure 'skin' aussi (voir son en-tête) — ce fichier
-- redéfinit maintenant la même liste, ce qui est volontaire et sans risque (`if exists` +
-- `create/add` derrière une valeur identique = no-op).

alter table public.character_catalogue drop constraint if exists character_catalogue_character_type_check;
alter table public.character_catalogue add constraint character_catalogue_character_type_check
  check (character_type in ('villager', 'special', 'standard', 'legendary', 'mythical', 'mega', 'gmax', 'regional', 'skin'));
