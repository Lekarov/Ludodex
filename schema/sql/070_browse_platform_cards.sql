-- Ludodex Online — 070 : parcours d'une plateforme dans l'album de la Collection, avec cartes
-- possédées en premier (triées par rareté) et filtre de rareté — demandé par Doktor. Fait tout le
-- tri/filtre côté serveur (une plateforme peut avoir des dizaines de milliers de cartes, comme
-- Switch avec 17 813 — impossible de trier "possédées d'abord" correctement en ne rapatriant
-- qu'une page à la fois sans ça, voir 069_platform_card_totals.sql pour le même type de problème).
--
-- SECURITY INVOKER (pas DEFINER) : pas besoin de bypasser la RLS, `collection` autorise déjà sa
-- propre lecture (collection_select_own_or_public, 004) et card_catalogue est public — cette
-- fonction n'a besoin d'aucun privilège élevé, juste d'agréger proprement.
create or replace function public.browse_platform_cards(
  p_platform text,
  p_rarity smallint default null,
  p_limit int default 60,
  p_offset int default 0
)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_profile uuid := auth.uid();
  v_limit int;
  v_items jsonb;
  v_total bigint;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  v_limit := least(coalesce(p_limit, 60), 200);

  select coalesce(jsonb_agg(row_to_json(t) order by t.rn), '[]'::jsonb), max(t.total_count)
    into v_items, v_total
  from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url, c.atk, c.def,
           c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           (own.card_id is not null) as owned,
           coalesce(own.owned_count, 0) as owned_count,
           coalesce(own.has_shiny, false) as owned_shiny,
           row_number() over (
             order by (own.card_id is not null) desc, c.rarity desc, c.title asc
           ) as rn,
           count(*) over() as total_count
    from public.card_catalogue c
    left join (
      select card_id, sum(count) as owned_count, bool_or(shiny) as has_shiny
      from public.collection
      where profile_id = v_profile
      group by card_id
    ) own on own.card_id = c.card_id
    where c.platform_name = p_platform
      and (p_rarity is null or c.rarity = p_rarity)
    order by (own.card_id is not null) desc, c.rarity desc, c.title asc
    limit v_limit offset p_offset
  ) t;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0));
end;
$$;

revoke execute on function public.browse_platform_cards(text, smallint, int, int) from public, anon;
grant execute on function public.browse_platform_cards(text, smallint, int, int) to authenticated;
