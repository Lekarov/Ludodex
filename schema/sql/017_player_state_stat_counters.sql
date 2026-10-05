-- Ludodex Online — 017 : compteurs cumulés nécessaires aux succès
-- Le prototype dérive ses succès de state.opened/state.golds/state.shinyDrawn/state.byR (compteurs
-- cumulés, jamais décrémentés même si une carte est ensuite défaussée/vendue). Rien de tel
-- n'existait côté serveur : collection ne reflète que l'état ACTUEL, pas l'historique.

alter table public.player_state
  add column if not exists boosters_opened_total integer not null default 0,
  add column if not exists golds_opened_total integer not null default 0,
  add column if not exists shiny_drawn_total integer not null default 0,
  add column if not exists pulls_rare integer not null default 0,       -- rareté 2 (Rare) ou mieux tirée au moins une fois compte ici à chaque tirage
  add column if not exists pulls_epic integer not null default 0,       -- rareté 3 (Épique)
  add column if not exists pulls_legendary integer not null default 0, -- rareté 4 (Légendaire)
  add column if not exists pulls_mythic integer not null default 0;    -- rareté 5 (Mythique)
