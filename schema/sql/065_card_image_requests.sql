-- Ludodex Online — 065 : demandes joueur de correction d'image + priorisation de la file de
-- triage (retour Doktor 29/09/2026) : sur la fiche détail d'une carte, un joueur peut signaler
-- que l'image lui semble cassée ; ça remonte en tête de la file de triage du hub (062-064) avec un
-- compteur visible.

create table if not exists public.card_image_requests (
  id uuid primary key default gen_random_uuid(),
  card_id text not null references public.card_catalogue(card_id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  comment text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists card_image_requests_open_idx on public.card_image_requests (card_id) where not resolved;
alter table public.card_image_requests enable row level security;

-- Un joueur voit ses propres demandes (pas celles des autres) ; l'équipe voit tout (pour le hub).
drop policy if exists "card_image_requests_select_own_or_staff" on public.card_image_requests;
create policy "card_image_requests_select_own_or_staff"
  on public.card_image_requests for select
  using (
    auth.uid() = reporter_id
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('moderator','admin','fondateur'))
  );
-- Pas de policy insert cliente directe : passe par report_card_image() ci-dessous (throttle +
-- vérifie que la carte existe).

-- Signalement joueur, n'importe quel compte connecté (pas réservé à l'équipe) — throttlé pour
-- éviter le spam (10/jour, réutilise _enforce_rate_limit de 060).
create or replace function public.report_card_image(p_card_id text, p_comment text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Authentification requise.';
  end if;
  perform public._enforce_rate_limit('report_card_image', 10, 86400);
  if not exists (select 1 from public.card_catalogue where card_id = p_card_id) then
    raise exception 'Carte introuvable.';
  end if;
  insert into public.card_image_requests (card_id, reporter_id, comment) values (p_card_id, auth.uid(), p_comment);
  -- Remet la carte en file de triage même si elle avait été marquée "done" (068/064) : un joueur
  -- qui signale un problème doit toujours faire réapparaître la carte, l'avis d'un modo passé ne
  -- doit pas masquer un vrai signalement récent.
  insert into public.card_image_review (card_id, status)
    values (p_card_id, 'pending')
    on conflict (card_id) do update set status = 'pending' where public.card_image_review.status = 'done';
end;
$$;

revoke execute on function public.report_card_image(text, text) from public, anon;
grant execute on function public.report_card_image(text, text) to authenticated;

-- File de triage priorisée : une carte avec au moins une demande non résolue passe devant tout le
-- reste (la plus signalée/la plus ancienne d'abord), sinon on retombe sur le tirage aléatoire
-- existant (064) parmi ce qui n'est pas "done".
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.image_url,
           coalesce(r.status, 'pending') as review_status,
           count(req.id) as request_count
    from public.card_image_requests req
    join public.card_catalogue c on c.card_id = req.card_id
    left join public.card_image_review r on r.card_id = c.card_id
    where not req.resolved
    group by c.card_id, c.title, c.platform_name, c.image_url, r.status
    order by count(req.id) desc, min(req.created_at) asc
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.image_url,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by random()
    limit 1
  ) t;
  return v_row;
end;
$$;

-- set_image_review_status (064) : résout aussi les demandes ouvertes quand on marque "done".
create or replace function public.set_image_review_status(p_card_id text, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  if p_status not in ('done', 'skipped', 'pending') then
    raise exception 'Statut invalide.';
  end if;
  insert into public.card_image_review (card_id, status, reviewed_by, reviewed_at)
    values (p_card_id, p_status, auth.uid(), now())
    on conflict (card_id) do update set status = p_status, reviewed_by = auth.uid(), reviewed_at = now();
  if p_status = 'done' then
    update public.card_image_requests set resolved = true where card_id = p_card_id and not resolved;
  end if;
end;
$$;

-- Badge du hub : nombre de cartes distinctes avec au moins une demande ouverte.
create or replace function public.count_open_image_requests()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public._require_elevated();
  select count(distinct card_id) into v_count from public.card_image_requests where not resolved;
  return v_count;
end;
$$;

revoke execute on function public.count_open_image_requests() from public, anon;
grant execute on function public.count_open_image_requests() to authenticated;
