-- Ludodex Online — 004 : collection de cartes par joueur
-- card_id référence le catalogue statique (fichiers JSON sur le NAS), pas une table SQL :
-- aucune clé étrangère possible ici, la cohérence est assurée côté application.

create table if not exists public.collection (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null,
  shiny boolean not null default false,
  count integer not null default 1,
  obtained_at timestamptz not null default now(),
  primary key (profile_id, card_id, shiny)
);

alter table public.collection enable row level security;

-- Le propriétaire voit toujours sa collection ; les autres joueurs seulement si elle est publique.
drop policy if exists "collection_select_own_or_public" on public.collection;
create policy "collection_select_own_or_public"
  on public.collection for select
  using (
    auth.uid() = profile_id
    or exists (
      select 1 from public.profiles p
      where p.id = collection.profile_id and p.collection_public = true
    )
  );

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- une carte n'est ajoutée que via une fonction serveur (ouverture de booster, achat au marché).
