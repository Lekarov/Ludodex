-- Ludodex Online — 007 : messages privés, signalements, blocages
-- Chat privé disponible dès le lancement, avec signalement/blocage dès le départ (décision
-- prise avec l'utilisateur, plus sensible qu'un salon public).

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

alter table public.blocks enable row level security;

drop policy if exists "blocks_select_own" on public.blocks;
create policy "blocks_select_own"
  on public.blocks for select
  using (auth.uid() = blocker_id);

drop policy if exists "blocks_insert_own" on public.blocks;
create policy "blocks_insert_own"
  on public.blocks for insert
  with check (auth.uid() = blocker_id);

drop policy if exists "blocks_delete_own" on public.blocks;
create policy "blocks_delete_own"
  on public.blocks for delete
  using (auth.uid() = blocker_id);

create table if not exists public.private_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

alter table public.private_messages enable row level security;

-- Lu uniquement par l'expéditeur et le destinataire (le modérateur passe par message_reports,
-- pas par un accès direct à toute la table).
drop policy if exists "private_messages_select_participants" on public.private_messages;
create policy "private_messages_select_participants"
  on public.private_messages for select
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- Envoi autorisé sauf si le destinataire a bloqué l'expéditeur.
drop policy if exists "private_messages_insert_if_not_blocked" on public.private_messages;
create policy "private_messages_insert_if_not_blocked"
  on public.private_messages for insert
  with check (
    auth.uid() = sender_id
    and not exists (
      select 1 from public.blocks b
      where b.blocker_id = recipient_id and b.blocked_id = sender_id
    )
  );

create table if not exists public.message_reports (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.private_messages(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null,
  status report_status not null default 'pending',
  reviewed_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.message_reports enable row level security;

drop policy if exists "message_reports_insert_own" on public.message_reports;
create policy "message_reports_insert_own"
  on public.message_reports for insert
  with check (auth.uid() = reporter_id);

drop policy if exists "message_reports_select_own_or_moderation" on public.message_reports;
create policy "message_reports_select_own_or_moderation"
  on public.message_reports for select
  using (
    auth.uid() = reporter_id
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('moderator', 'admin')
    )
  );

drop policy if exists "message_reports_update_moderation_only" on public.message_reports;
create policy "message_reports_update_moderation_only"
  on public.message_reports for update
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('moderator', 'admin')
    )
  );

-- Nettoyage à 30 jours : nécessite l'extension pg_cron (à activer depuis le dashboard,
-- Database → Extensions) puis planifier l'appel de cette fonction une fois par jour.
-- Non activé automatiquement ici — étape volontairement laissée à vous.
create or replace function public.purge_old_message_reports()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.message_reports where created_at < now() - interval '30 days';
$$;
