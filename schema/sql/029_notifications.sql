-- Ludodex Online — 029 : notifications (table + fonction interne de création)
-- Une notification par événement utile au joueur (succès débloqué, mise dépassée, enchère
-- gagnée, carte vendue, message reçu...). link_type/link_id disent au client où emmener le
-- joueur au clic (ex. link_type='listing', link_id=<uuid du market_listings> pour ouvrir le bon
-- onglet du Marché ; link_type='message', link_id=<profile_id de l'autre> pour ouvrir la
-- conversation). Écriture réservée aux fonctions serveur (create_notification, appelée en interne
-- par les RPC de succès/marché et par le trigger sur private_messages, jamais par le client
-- directement) — seule la lecture et le passage à "lu" sont ouverts au propriétaire.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  link_type text,
  link_id text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_profile_recent_idx
  on public.notifications (profile_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "notifications_select_own" on public.notifications;
create policy "notifications_select_own"
  on public.notifications for select
  using (auth.uid() = profile_id);

-- Le propriétaire peut seulement la marquer lue/non lue depuis son client (pas de risque à lui
-- laisser aussi réécrire titre/texte de ce qu'il voit déjà : simplification assumée, cette table
-- n'est pas une source de vérité pour l'état du jeu, juste un fil d'annonces).
drop policy if exists "notifications_update_own" on public.notifications;
create policy "notifications_update_own"
  on public.notifications for update
  using (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

create or replace function public.create_notification(
  p_profile uuid, p_type text, p_title text, p_body text, p_link_type text, p_link_id text
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.notifications (profile_id, type, title, body, link_type, link_id)
  values (p_profile, p_type, p_title, p_body, p_link_type, p_link_id);
$$;
