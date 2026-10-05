-- Ludodex Online — 034 : duels contre l'ordinateur (table historique + colonnes player_state)
-- Reprend le principe déjà validé dans PROMPT_REPRISE.md/social.html : deck de 5 cartes, chacune
-- comparée à un adversaire généré aléatoirement dans card_catalogue À LA MÊME RARETÉ (pas de vrai
-- PvP entre comptes, comme dans la démo), 5 duels/jour max, victoire = ATK-DEF le plus favorable.
-- duel_history est conservé indéfiniment (comme market_listings/market_bids) : chaque duel reste
-- consultable en détail via sa propre page (voir 035_rpc_run_duel.sql pour la fonction).

alter table public.player_state
  add column if not exists duel_date date,
  add column if not exists duels_played_today integer not null default 0,
  add column if not exists duel_wins_total integer not null default 0;

create table if not exists public.duel_history (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  won boolean not null,
  my_wins integer not null,
  their_wins integer not null,
  reward integer not null,
  rounds jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists duel_history_profile_idx on public.duel_history (profile_id, created_at desc);

alter table public.duel_history enable row level security;

drop policy if exists "duel_history_select_own" on public.duel_history;
create policy "duel_history_select_own"
  on public.duel_history for select
  using (auth.uid() = profile_id);

-- Volontairement aucune policy insert/update/delete : uniquement écrit par run_duel() (035).
