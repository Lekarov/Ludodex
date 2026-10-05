-- Ludodex Online — 053 : la vue all_cards_catalogue expose la vraie description_fr d'un
-- personnage (052_character_catalogue_description.sql) au lieu d'un null en dur — sans ça
-- bioHTML/cardSubText retombent toujours sur species/quote même une fois les descriptions
-- générées et importées.

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
  null::text as description_en, description_fr,
  coalesce(species, quote) as genres
from public.character_catalogue;

grant select on public.all_cards_catalogue to anon, authenticated;
