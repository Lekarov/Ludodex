-- Ludodex Online — 069 : vue de comptage par plateforme, pour l'album de la Collection.
--
-- Bug réel trouvé (Doktor : "Switch je suis à 38/32 alors que je ne les ai pas toutes") :
-- `loadAlbumShelf()` (web/js/collection.js) faisait `select("platform_name, family_color")` sur
-- TOUT `card_catalogue` (239 000+ lignes) sans pagination pour compter les totaux par plateforme
-- côté client. PostgREST plafonne une réponse à 1000 lignes par défaut (`max-rows`) — le total
-- affiché n'était donc calculé que sur les 1000 premières lignes de la table, pas sur l'ensemble :
-- Switch a réellement 17 813 cartes, pas 32. "Possédées" (owned), lui, était juste (confirmé par
-- requête directe), donc owned pouvait dépasser ce faux total tronqué.
--
-- Fix : un vrai comptage GROUP BY côté serveur (une seule ligne par plateforme en retour, ~40
-- lignes au lieu de 239 000) au lieu de tout rapatrier pour compter en JS.
create or replace view public.platform_card_totals
with (security_invoker = true) as
select platform_name, min(family_color) as family_color, count(*) as total
from public.card_catalogue
group by platform_name;

-- Lecture publique, comme card_catalogue lui-même (card_catalogue_select_all, 015) : c'est un pur
-- agrégat de données déjà publiques, utilisé par la Collection de tous les joueurs.
grant select on public.platform_card_totals to anon, authenticated;
