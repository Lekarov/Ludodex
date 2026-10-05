-- Ludodex Online — 037 : liste de souhaits
-- Un joueur ajoute une carte qu'il ne possède pas (n'importe laquelle des 203 000+ de
-- card_catalogue) ; voir 038_notify_wishlist.sql pour l'alerte à la mise en vente.

create table if not exists public.wishlist (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null references public.card_catalogue(card_id),
  created_at timestamptz not null default now(),
  primary key (profile_id, card_id)
);

create index if not exists wishlist_card_idx on public.wishlist (card_id);

alter table public.wishlist enable row level security;

drop policy if exists "wishlist_select_own" on public.wishlist;
create policy "wishlist_select_own"
  on public.wishlist for select
  using (auth.uid() = profile_id);

drop policy if exists "wishlist_insert_own" on public.wishlist;
create policy "wishlist_insert_own"
  on public.wishlist for insert
  with check (auth.uid() = profile_id);

drop policy if exists "wishlist_delete_own" on public.wishlist;
create policy "wishlist_delete_own"
  on public.wishlist for delete
  using (auth.uid() = profile_id);
