-- Ludodex Online — 002 : profils
-- Un profil par compte, créé automatiquement à l'inscription (jamais par le client directement).

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  role profile_role not null default 'player',
  collection_public boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Lecture publique : nécessaire pour afficher un vendeur sur le marché ou un pseudo en chat.
drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all"
  on public.profiles for select
  using (true);

-- Un joueur ne modifie que son propre réglage de confidentialité de collection, jamais son rôle.
drop policy if exists "profiles_update_own_non_role_fields" on public.profiles;
create policy "profiles_update_own_non_role_fields"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Empêche un joueur de changer son propre rôle même via la policy d'update ci-dessus :
-- seul un appel effectué avec la clé de service (donc hors RLS) peut changer `role`.
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
as $$
begin
  if new.role is distinct from old.role and auth.uid() = old.id then
    raise exception 'Le rôle ne peut pas être modifié par le joueur lui-même.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_role_self_escalation on public.profiles;
create trigger trg_prevent_role_self_escalation
  before update on public.profiles
  for each row execute function public.prevent_role_self_escalation();

-- Création automatique du profil à l'inscription (email/mdp, Google ou Discord).
-- Le username par défaut est temporaire (à partir de l'email) ; le joueur pourra le changer
-- ensuite via son propre update (soumis à la contrainte unique).
-- LIMITE CONNUE : si deux comptes ont le même préfixe d'email, l'insert peut échouer sur la
-- contrainte unique de `username` et bloquer l'inscription. À renforcer avant la mise en ligne
-- réelle (par ex. suffixe aléatoire systématique) — noté ici, pas encore corrigé.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(split_part(new.email, '@', 1), 'joueur_' || substr(new.id::text, 1, 8)));
  return new;
end;
$$;

drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
  after insert on auth.users
  for each row execute function public.handle_new_user();
