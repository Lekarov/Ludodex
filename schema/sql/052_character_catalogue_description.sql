-- Ludodex Online — 052 : description française par personnage (character_catalogue)
-- Même besoin que 036_card_catalogue_descriptions.sql côté jeux : jusqu'ici la bio d'un
-- personnage repliait sur species/quote (voir 048_all_cards_view.sql), pas un vrai texte dédié.
-- Rempli ensuite par un script de génération (voir schema/catalogue_import/), colonne nullable en
-- attendant — bioHTML (detail.js) et cardSubText (render.js) replient déjà sur genres/quote tant
-- qu'une ligne n'a pas encore de description_fr.

alter table public.character_catalogue add column if not exists description_fr text;
