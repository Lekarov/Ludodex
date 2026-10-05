-- Ludodex Online — 044 : character_catalogue, table séparée de card_catalogue pour les
-- personnages de jeux vidéo (à distinguer des fiches "jeu" existantes). Démarre avec Animal
-- Crossing (566 fiches : 490 villageois + 76 personnages spéciaux, récupérés via l'API Cargo
-- publique de Nookipedia — voir schema/catalogue_import/generate_character_catalogue.js).
--
-- Séparée volontairement de card_catalogue : un personnage n'a pas de plateforme/année de sortie
-- unique (il apparaît dans plusieurs jeux), et rien ne dit encore si/comment ces fiches seront
-- mêlées aux boosters/collection existants — cette table n'est pour l'instant qu'un catalogue
-- consultable, aucune RPC de jeu n'y touche.
--
-- Même schéma de rareté que card_catalogue (percentile 0-5 calculé sur ce catalogue séparément),
-- même politique RLS (lecture publique, écriture réservée au rôle de service).

create table if not exists public.character_catalogue (
  character_id text primary key,
  franchise text not null,
  character_type text not null check (character_type in ('villager', 'special')),
  name text not null,
  species text,
  personality text,
  gender text,
  birthday text,
  quote text,
  games text,
  rarity smallint not null check (rarity between 0 and 5),
  rarity_name text not null,
  rarity_color text not null,
  family_color text not null,
  image_url text,
  atk integer not null,
  def integer not null,
  updated_at timestamptz not null default now()
);

create index if not exists character_catalogue_franchise_idx on public.character_catalogue (franchise);
create index if not exists character_catalogue_rarity_idx on public.character_catalogue (rarity);

alter table public.character_catalogue enable row level security;

drop policy if exists "character_catalogue_select_all" on public.character_catalogue;
create policy "character_catalogue_select_all"
  on public.character_catalogue for select
  using (true);
