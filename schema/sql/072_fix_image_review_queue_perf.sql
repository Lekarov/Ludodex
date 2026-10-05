-- Ludodex Online — 072 : même audit RPC que 071, deuxième trouvaille (moindre : réservé à
-- l'équipe, appelé une carte à la fois, pas un chemin chaud joueur) — get_next_image_review_card()
-- (064/065/066) tirait sa carte de repli avec `ORDER BY random() LIMIT 1` sur tout card_catalogue
-- (239 000+ lignes) au lieu de réutiliser l'index `(rarity, random_key)` déjà posé par 047. Corrigé
-- avec la même technique de seuil + repli que run_duel (071)/open_booster.
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb;
  v_threshold double precision;
begin
  perform public._require_elevated();

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           count(req.id) as request_count
    from public.card_image_requests req
    join public.card_catalogue c on c.card_id = req.card_id
    left join public.card_image_review r on r.card_id = c.card_id
    where not req.resolved
    group by c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url, c.atk, c.def,
             c.rarity, c.rarity_name, c.rarity_color, c.family_color,
             c.image_pos_x, c.image_pos_y, c.image_scale, r.status
    order by count(req.id) desc, min(req.created_at) asc
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  v_threshold := random();
  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done' and c.random_key >= v_threshold
    order by c.random_key
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by c.random_key
    limit 1
  ) t;
  return v_row;
end;
$$;
