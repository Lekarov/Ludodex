-- Ludodex Online — 016 : clés étrangères vers card_catalogue
-- À exécuter APRÈS avoir réimporté card_catalogue.csv suite à 015 (la table doit être peuplée,
-- sinon cette contrainte échoue dès qu'un compte a déjà des cartes en collection).
-- Ces deux tables ne stockaient qu'un card_id texte libre jusqu'ici ; la contrainte garantit
-- désormais qu'il pointe toujours vers une carte réelle du catalogue, et permet à supabase-js de
-- faire des requêtes imbriquées (select("*, card_catalogue(*)")) au lieu de deux appels séparés.

alter table public.collection
  drop constraint if exists collection_card_id_fkey;
alter table public.collection
  add constraint collection_card_id_fkey foreign key (card_id) references public.card_catalogue(card_id);

alter table public.market_listings
  drop constraint if exists market_listings_card_id_fkey;
alter table public.market_listings
  add constraint market_listings_card_id_fkey foreign key (card_id) references public.card_catalogue(card_id);
