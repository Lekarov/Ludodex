-- Ludodex Online — 008 : catalogue de cartes (id stable + rareté)
-- Copie minimale du catalogue (pas de titre, image, description : ça reste sur le NAS) pour que
-- les fonctions serveur (RPC, étape suivante) puissent tirer un booster sans faire confiance au
-- client. card_id = `id` stable des sources catalogue (ex. "igdb:12345"), jamais l'index de
-- tableau utilisé côté client dans GAMES — voir passation du 26/09/2026 pour le pourquoi.
--
-- Contenu généré par schema/catalogue_import/generate_card_catalogue.js (rejoue exactement
-- computeStats + assignRarity de site/js/data/catalogue-loader.js) puis importé manuellement
-- (Table Editor → card_catalogue → Insert → Import data from CSV) depuis
-- schema/catalogue_import/card_catalogue.csv. À régénérer et réimporter si le catalogue change
-- de façon notable (la rareté est un classement par percentile sur tout le catalogue).

create table if not exists public.card_catalogue (
  card_id text primary key,
  rarity smallint not null check (rarity between 0 and 5),
  updated_at timestamptz not null default now()
);

alter table public.card_catalogue enable row level security;

-- Lecture publique : les fonctions serveur (security definer) n'en ont pas besoin, mais rien
-- n'est sensible ici (juste un id et une rareté), et ça évite de bloquer un futur usage client
-- en lecture seule (ex. filtrer le marché par rareté sans dupliquer cette info).
drop policy if exists "card_catalogue_select_all" on public.card_catalogue;
create policy "card_catalogue_select_all"
  on public.card_catalogue for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié : l'import se fait
-- par vous via le Table Editor (bypass RLS), jamais par un joueur.
