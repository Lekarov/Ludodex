-- Ludodex Online — 009 : compteur de pity (booster doré)
-- Manquait dans 003 : nécessaire pour reproduire côté serveur "le 10e booster est doré"
-- (state.sinceGold côté site, voir site/js/engine/packs.js et GOLD_EVERY dans constants.js).

alter table public.player_state
  add column if not exists opens_since_gold integer not null default 0;
