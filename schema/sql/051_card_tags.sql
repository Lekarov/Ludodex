-- Ludodex Online — 051 : tags personnels sur une carte (fiche détail)
-- Étiquettes libres posées par le joueur sur une carte pour s'organiser (ex. "à échanger",
-- "pour le deck duel") — demandées à l'utilisateur "étiquettes" côté WikiMasters, appelées "tags"
-- ici. Pas de FK vers card_catalogue : all_cards_catalogue (048) mélange jeux et personnages sous
-- le même nom de colonne card_id mais deux tables sources différentes, une carte tag doit marcher
-- pour les deux sans distinction.

create table if not exists public.card_tags (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null,
  tag text not null check (char_length(tag) between 1 and 32),
  created_at timestamptz not null default now(),
  primary key (profile_id, card_id, tag)
);

create index if not exists card_tags_profile_idx on public.card_tags (profile_id, tag);

alter table public.card_tags enable row level security;

drop policy if exists "card_tags_select_own" on public.card_tags;
create policy "card_tags_select_own"
  on public.card_tags for select
  using (auth.uid() = profile_id);

drop policy if exists "card_tags_insert_own" on public.card_tags;
create policy "card_tags_insert_own"
  on public.card_tags for insert
  with check (auth.uid() = profile_id);

drop policy if exists "card_tags_delete_own" on public.card_tags;
create policy "card_tags_delete_own"
  on public.card_tags for delete
  using (auth.uid() = profile_id);
