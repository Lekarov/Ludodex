-- Ludodex Online — 042 : cartes Gold uniques (un seul exemplaire dans tout le jeu)
-- Volontairement SÉPARÉ de `collection` (pas une variante comme `shiny`, décision utilisateur du
-- 27/09/2026) : une carte Gold n'entre jamais dans le marché/échanges/défausse pour l'instant, ne
-- touche donc AUCUNE des ~10 fonctions déjà construites autour de `collection`. Juste un registre
-- global : la clé primaire sur card_id garantit qu'un jeu ne peut avoir qu'UN SEUL propriétaire
-- Gold dans tout Ludodex Online, jamais deux, même en cas de tirages simultanés (contrainte au
-- niveau base, pas juste vérifiée côté application).

create table if not exists public.gold_claims (
  card_id text primary key references public.card_catalogue(card_id),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  claimed_at timestamptz not null default now()
);

create index if not exists gold_claims_profile_idx on public.gold_claims (profile_id, claimed_at desc);

alter table public.gold_claims enable row level security;

-- Public comme card_catalogue/market_listings : "qui possède quelle carte Gold" fait partie du
-- prestige de la carte, pas une donnée privée.
drop policy if exists "gold_claims_select_all" on public.gold_claims;
create policy "gold_claims_select_all"
  on public.gold_claims for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour authenticated : uniquement écrit par
-- open_booster() (043), qui vérifie déjà l'authentification et gère la course en cas de tirage
-- simultané via la contrainte de clé primaire (exception unique_violation attrapée).
