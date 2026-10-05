-- Ludodex Online — 048 : vue unifiée jeux + personnages pour "Toutes les cartes" (web/cards.html).
-- Décision utilisateur : les personnages (character_catalogue) rejoignent le même écran de
-- parcours que les jeux (card_catalogue), pas une page séparée — juste un filtre en plus, sans
-- surcharger l'interface.
--
-- `card_id` reste le nom de colonne (alias de `character_id` côté personnages) pour ne rien
-- changer côté client : detail.js, la liste de souhaits, lastBatch etc. utilisent déjà ce nom.
-- `platform_name` porte la plateforme pour un jeu, la franchise pour un personnage (même usage à
-- l'affichage : ligne "développeur · plateforme/franchise · année" sous le titre). `genres` porte
-- un repli texte (espèce/rôle du personnage) pour que la bio affiche quelque chose de pertinent
-- même sans description longue (même logique de repli que card_catalogue, voir detail.js).
-- `kind` ('game'/'character') distingue les deux à l'affichage (actions/marché/liste de souhaits
-- n'existent que pour les jeux, voir web/js/detail.js) et sert de filtre principal côté UI.
--
-- Vue simple (pas de security barrier nécessaire) : elle hérite du RLS des deux tables sources,
-- toutes deux déjà en lecture publique.

create or replace view public.all_cards_catalogue as
select
  card_id, 'game'::text as kind, title, platform_name, year, developer, image_url,
  rarity, rarity_name, rarity_color, family_color, atk, def,
  description_en, description_fr, genres
from public.card_catalogue
union all
select
  character_id as card_id, 'character'::text as kind, name as title, franchise as platform_name,
  null::integer as year, null::text as developer, image_url,
  rarity, rarity_name, rarity_color, family_color, atk, def,
  null::text as description_en, null::text as description_fr,
  coalesce(species, quote) as genres
from public.character_catalogue;

grant select on public.all_cards_catalogue to anon, authenticated;
