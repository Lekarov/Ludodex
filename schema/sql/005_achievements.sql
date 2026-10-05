-- Ludodex Online — 005 : succès débloqués
-- Trace permanente du versement de la récompense, pour ne jamais la donner deux fois même si
-- le succès est retravaillé plus tard.

create table if not exists public.achievements_unlocked (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  achievement_id text not null,
  unlocked_at timestamptz not null default now(),
  reward_granted boolean not null default false,
  reward_granted_at timestamptz,
  primary key (profile_id, achievement_id)
);

alter table public.achievements_unlocked enable row level security;

drop policy if exists "achievements_select_own" on public.achievements_unlocked;
create policy "achievements_select_own"
  on public.achievements_unlocked for select
  using (auth.uid() = profile_id);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- un succès n'est débloqué et récompensé que via une fonction serveur.
