-- Ludodex Online — 006 : marché (annonces et enchères)
-- Vendeur/acheteur générique (bot ou joueur) dès maintenant, même si seuls les bots
-- vendent/achètent au début (décision prise avec l'utilisateur).

create table if not exists public.market_listings (
  id uuid primary key default gen_random_uuid(),
  seller_type market_party_type not null,
  seller_profile_id uuid references public.profiles(id) on delete cascade,
  bot_name text,
  card_id text not null,
  shiny boolean not null default false,
  listing_type listing_type not null,
  price integer,
  status listing_status not null default 'active',
  created_at timestamptz not null default now(),
  constraint seller_matches_type check (
    (seller_type = 'player' and seller_profile_id is not null and bot_name is null)
    or (seller_type = 'bot' and seller_profile_id is null and bot_name is not null)
  )
);

alter table public.market_listings enable row level security;

-- Le marché est public : tout le monde voit toutes les annonces.
drop policy if exists "market_listings_select_all" on public.market_listings;
create policy "market_listings_select_all"
  on public.market_listings for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- une annonce n'est créée/résolue que via une fonction serveur (vérifie la carte possédée,
-- débite/crédite les pièces de façon atomique).

create table if not exists public.market_bids (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.market_listings(id) on delete cascade,
  bidder_type market_party_type not null,
  bidder_profile_id uuid references public.profiles(id) on delete cascade,
  amount integer not null,
  created_at timestamptz not null default now(),
  constraint bidder_matches_type check (
    (bidder_type = 'player' and bidder_profile_id is not null)
    or (bidder_type = 'bot' and bidder_profile_id is null)
  )
);

alter table public.market_bids enable row level security;

drop policy if exists "market_bids_select_all" on public.market_bids;
create policy "market_bids_select_all"
  on public.market_bids for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- une enchère n'est acceptée que via une fonction serveur qui vérifie les fonds du joueur.
