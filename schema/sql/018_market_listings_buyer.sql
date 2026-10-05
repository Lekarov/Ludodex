-- Ludodex Online — 018 : traçabilité de l'acheteur sur une vente
-- Nécessaire pour le succès "Premier achat" (m1) et un futur historique d'achats : jusqu'ici
-- buy_listing() ne laissait aucune trace de qui avait acheté une annonce une fois vendue.

alter table public.market_listings
  add column if not exists buyer_profile_id uuid references public.profiles(id);
