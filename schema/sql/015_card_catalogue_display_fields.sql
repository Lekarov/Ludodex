-- Ludodex Online — 015 : card_catalogue devient aussi la source d'affichage
-- Jusqu'ici jeu.js téléchargeait tout le catalogue (~32 000 jeux, dont un fichier de ~16 Mo)
-- côté navigateur juste pour retrouver le titre/l'image des quelques cartes possédées par le
-- joueur — beaucoup trop lent pour un usage réel. On enrichit card_catalogue avec les champs
-- d'affichage nécessaires (titre, plateforme, année, image, ATK/DEF, couleur de rareté) pour
-- que le client n'ait plus qu'à demander à Supabase les cartes qu'il affiche réellement.
--
-- Table entièrement recréée (DROP + CREATE) plutôt qu'ALTER, plus simple pour changer autant de
-- colonnes d'un coup sur une table qui ne contient que des données dérivées, régénérables.
--
-- IMPORTANT — ORDRE : ce fichier recrée la table VIDE. Réimportez le CSV régénéré
-- (schema/catalogue_import/card_catalogue.csv, Table Editor → card_catalogue → Insert → Import
-- data from CSV) AVANT d'exécuter 016 (qui ajoute les clés étrangères depuis collection et
-- market_listings) — sinon 016 échoue si un compte a déjà des cartes en collection.

drop table if exists public.card_catalogue cascade;

create table public.card_catalogue (
  card_id text primary key,
  rarity smallint not null check (rarity between 0 and 5),
  rarity_name text not null,
  rarity_color text not null,
  family_color text not null,
  title text not null,
  platform_name text not null,
  year integer,
  developer text,
  image_url text,
  atk integer not null,
  def integer not null,
  updated_at timestamptz not null default now()
);

alter table public.card_catalogue enable row level security;

create policy "card_catalogue_select_all"
  on public.card_catalogue for select
  using (true);
