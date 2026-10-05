-- Ludodex Online — 032 : échanges joueur-à-joueur (table)
-- Remplace la démo locale de social.html (négociation simulée avec des amis inventés) par de
-- vrais échanges entre deux comptes réels. Cartes stockées en jsonb ([{card_id,shiny,count}, ...])
-- plutôt qu'une table de jonction : plus simple à valider d'un bloc dans les RPC (033), et la
-- liste ne sert qu'à décrire une proposition, jamais interrogée carte par carte ailleurs.
-- Modèle retenu, identique au marché (014/023) : proposer une offre RETIRE immédiatement les
-- cartes offertes de la collection du proposeur (séquestre), pour empêcher de les revendre ou
-- défausser pendant que la proposition est en attente. Rendues si refusée/annulée.

create table if not exists public.trade_offers (
  id uuid primary key default gen_random_uuid(),
  from_profile uuid not null references public.profiles(id) on delete cascade,
  to_profile uuid not null references public.profiles(id) on delete cascade,
  offered jsonb not null,
  requested jsonb not null,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  constraint trade_offers_status_check check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  constraint trade_offers_not_self check (from_profile <> to_profile)
);

create index if not exists trade_offers_to_profile_idx on public.trade_offers (to_profile, status, created_at desc);
create index if not exists trade_offers_from_profile_idx on public.trade_offers (from_profile, created_at desc);

alter table public.trade_offers enable row level security;

drop policy if exists "trade_offers_select_participants" on public.trade_offers;
create policy "trade_offers_select_participants"
  on public.trade_offers for select
  using (auth.uid() = from_profile or auth.uid() = to_profile);

-- Volontairement aucune policy insert/update/delete : proposer/répondre/annuler passe par les RPC
-- de 033_rpc_trades.sql, qui déplacent réellement les cartes de façon atomique et vérifiée.
