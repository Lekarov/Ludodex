-- Ludodex Online — 073 : canal de contact/support joueur → équipe, séparé de message_reports
-- (007, qui reste réservé aux signalements ENTRE joueurs). Décision Tier 4 : un joueur avec un bug
-- ou un souci de compte doit pouvoir contacter directement l'équipe, sans passer par un autre
-- joueur à signaler.

do $$ begin
  create type support_ticket_status as enum ('open', 'in_progress', 'closed');
exception when duplicate_object then null; end $$;

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null,
  message text not null,
  status support_ticket_status not null default 'open',
  staff_note text,
  resolved_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists support_tickets_status_idx on public.support_tickets (status, created_at desc);
alter table public.support_tickets enable row level security;

drop policy if exists "support_tickets_select_own_or_staff" on public.support_tickets;
create policy "support_tickets_select_own_or_staff"
  on public.support_tickets for select
  using (
    auth.uid() = profile_id
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('moderator','admin','fondateur'))
  );
-- Pas de policy insert/update cliente directe : passe par submit_support_ticket()/
-- resolve_support_ticket() ci-dessous (throttle à l'envoi, audit à la résolution).

create or replace function public.submit_support_ticket(p_subject text, p_message text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_profile uuid := auth.uid(); v_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  perform public._enforce_rate_limit('submit_support_ticket', 5, 86400);
  if p_subject is null or length(trim(p_subject)) = 0 then
    raise exception 'Sujet requis.';
  end if;
  if p_message is null or length(trim(p_message)) = 0 then
    raise exception 'Message requis.';
  end if;
  insert into public.support_tickets (profile_id, subject, message)
    values (v_profile, trim(p_subject), trim(p_message))
    returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.submit_support_ticket(text, text) from public, anon;
grant execute on function public.submit_support_ticket(text, text) to authenticated;

-- ===== Côté hub (staff, via _require_elevated déjà posé par 062/063) =====

create or replace function public.list_support_tickets(p_status text default 'open')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  perform public._require_elevated();
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select st.id, st.subject, st.message, st.status, st.staff_note, st.created_at, st.resolved_at,
           p.username
    from public.support_tickets st
    join public.profiles p on p.id = st.profile_id
    where p_status is null or st.status = p_status::support_ticket_status
    order by st.created_at desc
    limit 100
  ) t;
  return v_result;
end;
$$;

revoke execute on function public.list_support_tickets(text) from public, anon;
grant execute on function public.list_support_tickets(text) to authenticated;

create or replace function public.resolve_support_ticket(p_id uuid, p_status text, p_staff_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_ticket public.support_tickets%rowtype;
begin
  perform public._require_elevated();
  if p_status not in ('open', 'in_progress', 'closed') then
    raise exception 'Statut invalide.';
  end if;
  select * into v_ticket from public.support_tickets where id = p_id;
  if not found then
    raise exception 'Ticket introuvable.';
  end if;

  update public.support_tickets set
    status = p_status::support_ticket_status,
    staff_note = coalesce(p_staff_note, staff_note),
    resolved_by = case when p_status = 'closed' then auth.uid() else resolved_by end,
    resolved_at = case when p_status = 'closed' then now() else resolved_at end
  where id = p_id;

  if p_status = 'closed' and v_ticket.status <> 'closed' then
    perform public.create_notification(
      v_ticket.profile_id, 'support_resolved', 'Ta demande a été traitée',
      'Ton message "' || v_ticket.subject || '" a été traité par l''équipe.',
      null, null
    );
  end if;
end;
$$;

revoke execute on function public.resolve_support_ticket(uuid, text, text) from public, anon;
grant execute on function public.resolve_support_ticket(uuid, text, text) to authenticated;

create or replace function public.count_open_support_tickets()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public._require_elevated();
  select count(*) into v_count from public.support_tickets where status in ('open', 'in_progress');
  return v_count;
end;
$$;

revoke execute on function public.count_open_support_tickets() from public, anon;
grant execute on function public.count_open_support_tickets() to authenticated;
