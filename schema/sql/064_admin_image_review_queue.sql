-- Ludodex Online — 064 : file de triage des images du catalogue (retour Doktor 29/09/2026 : le
-- gestionnaire d'images de 063, recherche par card_id exact, était "vide et incomplet" — il
-- voulait une vraie file à parcourir carte par carte avec deux choix : "Fait" (validé
-- définitivement, ne revient plus sauf si quelqu'un change la DA plus tard) et "Passer" (revient
-- plus tard, tiré au hasard parmi les cartes non encore validées).

create table if not exists public.card_image_review (
  card_id text primary key references public.card_catalogue(card_id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'done', 'skipped')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz
);
alter table public.card_image_review enable row level security;
-- Aucune policy cliente directe : uniquement via les fonctions ci-dessous (staff + élévation).

-- Tire une carte au hasard parmi celles jamais marquées "done" (donc "pending" jamais vues ET
-- "skipped" déjà passées reviennent toutes les deux dans le tirage, mélangées) — c'est le "revient
-- plus tard de manière aléatoire" demandé. Exclut définitivement les "done".
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();
  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.image_url,
           coalesce(r.status, 'pending') as review_status
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by random()
    limit 1
  ) t;
  return v_row;
end;
$$;

revoke execute on function public.get_next_image_review_card() from public, anon;
grant execute on function public.get_next_image_review_card() to authenticated;

-- p_status : 'done' (validation définitive) ou 'skipped' (revient plus tard). Repasser une carte
-- "done" en file (changement de DA) se fait juste en rappelant cette fonction avec 'skipped' ou
-- 'pending' sur ce card_id — pas besoin d'une fonction séparée, un modo/admin peut le refaire
-- depuis la recherche directe (image déjà existante par card_id, gardée en plus de la file).
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
end;
$$;

revoke execute on function public.set_image_review_status(text, text) from public, anon;
grant execute on function public.set_image_review_status(text, text) to authenticated;

-- Compteur pour l'en-tête de l'onglet Images (combien de cartes restent à trier).
create or replace function public.count_pending_image_reviews()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public._require_elevated();
  select count(*) into v_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done';
  return v_count;
end;
$$;

revoke execute on function public.count_pending_image_reviews() from public, anon;
grant execute on function public.count_pending_image_reviews() to authenticated;
