-- Ludodex Online — 056 : vraie liste d'amis (remplace la démo locale de social.html) + purge
-- automatique des messages privés de plus de 30 jours.

/* ===== Amis ===== */

create table if not exists public.friends (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  constraint friends_no_self check (requester_id <> addressee_id),
  constraint friends_unique_pair unique (requester_id, addressee_id)
);

alter table public.friends enable row level security;

drop policy if exists "friends_select_participant" on public.friends;
create policy "friends_select_participant"
  on public.friends for select
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

drop policy if exists "friends_insert_as_requester" on public.friends;
create policy "friends_insert_as_requester"
  on public.friends for insert
  with check (auth.uid() = requester_id);

-- Seul le destinataire peut accepter (pending -> accepted) ; personne ne peut rétrograder une
-- amitié acceptée par update (il faut la supprimer, voir la policy delete ci-dessous).
drop policy if exists "friends_update_addressee_accept" on public.friends;
create policy "friends_update_addressee_accept"
  on public.friends for update
  using (auth.uid() = addressee_id and status = 'pending')
  with check (status = 'accepted');

-- Les deux camps peuvent supprimer la relation (annuler une demande envoyée, refuser une demande
-- reçue, ou retirer un ami existant).
drop policy if exists "friends_delete_participant" on public.friends;
create policy "friends_delete_participant"
  on public.friends for delete
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create index if not exists friends_addressee_idx on public.friends(addressee_id, status);
create index if not exists friends_requester_idx on public.friends(requester_id, status);

/* ===== Purge des messages privés ===== */
-- Même mécanisme que purge_old_notifications (050_notifications_purge.sql) : chaque message
-- privé (007_messages_and_moderation.sql) survit 30 jours après son envoi puis disparaît
-- individuellement via ce job quotidien, pour ne pas accumuler indéfiniment du stockage inutile.

create extension if not exists pg_cron;

create or replace function public.purge_old_private_messages()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.private_messages where created_at < now() - interval '30 days';
$$;

do $$
begin
  perform cron.unschedule('purge_old_private_messages_daily');
exception when others then null;
end $$;

select cron.schedule(
  'purge_old_private_messages_daily',
  '0 4 * * *', -- tous les jours à 4h (heure du serveur, UTC) — décalé de purge_old_notifications
  $$select public.purge_old_private_messages();$$
);
