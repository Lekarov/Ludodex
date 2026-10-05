-- Ludodex Online — 022 : date de fin pour les enchères
-- Nécessaire pour savoir quand une enchère se termine et doit être résolue (voir 023).

alter table public.market_listings
  add column if not exists ends_at timestamptz;
