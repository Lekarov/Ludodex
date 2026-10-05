-- Ludodex Online — 054 : photo de profil + vitrine de 4 cartes
-- La "photo de profil" n'est pas un fichier uploadé (pas d'infra de stockage/modération pour ça
-- pour l'instant) : le joueur choisit une carte de SA collection, dont l'illustration sert
-- d'avatar (cohérent avec un jeu de cartes, évite d'ouvrir un système d'upload d'images libres).
-- Même logique pour la vitrine : 4 emplacements, chacun une carte de la collection.

alter table public.profiles add column if not exists avatar_card_id text;
alter table public.profiles add column if not exists avatar_shiny boolean not null default false;

-- Pas de FK vers card_catalogue : une carte de vitrine/avatar peut être un personnage
-- (character_catalogue, via all_cards_catalogue) — voir 051_card_tags.sql pour le même choix.
create table if not exists public.profile_showcase (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  slot smallint not null check (slot between 1 and 4),
  card_id text not null,
  shiny boolean not null default false,
  primary key (profile_id, slot)
);

alter table public.profile_showcase enable row level security;

-- Lecture publique : une vitrine n'a de sens que vue par d'autres joueurs (futur profil public) ;
-- ce n'est pas une donnée sensible (juste "quelles cartes ce joueur met en avant").
drop policy if exists "profile_showcase_select_all" on public.profile_showcase;
create policy "profile_showcase_select_all"
  on public.profile_showcase for select
  using (true);

drop policy if exists "profile_showcase_upsert_own" on public.profile_showcase;
create policy "profile_showcase_upsert_own"
  on public.profile_showcase for insert
  with check (auth.uid() = profile_id);

drop policy if exists "profile_showcase_update_own" on public.profile_showcase;
create policy "profile_showcase_update_own"
  on public.profile_showcase for update
  using (auth.uid() = profile_id);

drop policy if exists "profile_showcase_delete_own" on public.profile_showcase;
create policy "profile_showcase_delete_own"
  on public.profile_showcase for delete
  using (auth.uid() = profile_id);
