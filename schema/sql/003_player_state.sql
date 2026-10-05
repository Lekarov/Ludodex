-- Ludodex Online — 003 : état de jeu (pièces, boosters)
-- Aucune écriture cliente n'est autorisée sur cette table : seules des fonctions serveur
-- (à écrire dans une étape suivante) pourront la modifier, en s'exécutant avec les droits du
-- propriétaire de la table (qui contourne naturellement la RLS ci-dessous).

create table if not exists public.player_state (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  coins integer not null default 0,
  boosters_available integer not null default 0,
  last_regen_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.player_state enable row level security;

-- Lecture strictement privée : personne d'autre ne voit le solde de pièces d'un joueur.
drop policy if exists "player_state_select_own" on public.player_state;
create policy "player_state_select_own"
  on public.player_state for select
  using (auth.uid() = profile_id);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- toute mutation devra passer par une fonction serveur dédiée (étape suivante).

-- Création automatique d'un état de jeu par défaut en même temps que le profil.
create or replace function public.handle_new_player_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.player_state (profile_id) values (new.id);
  return new;
end;
$$;

drop trigger if exists trg_handle_new_player_state on public.profiles;
create trigger trg_handle_new_player_state
  after insert on public.profiles
  for each row execute function public.handle_new_player_state();
