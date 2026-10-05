-- Ludodex Online — 066 : éditeur de catalogue complet dans le hub (retour Doktor 29/09/2026,
-- deuxième vague) : la simple recherche par card_id ne suffisait pas — il veut parcourir le
-- catalogue comme la page "Collection" (grille de vraies cartes rendues, cardHTML()), choisir une
-- carte manuellement, et dans un gros panneau d'édition ajuster : l'URL d'image (aperçu en direct),
-- le cadrage de l'image (position via flèches directionnelles, zoom +/-), la rareté, l'ATK et le DEF.
--
-- Le cadrage (position/zoom) doit affecter le RENDU RÉEL de la carte partout sur le site (pas
-- juste un aperçu dans le hub) : nouvelles colonnes lues par cardHTML() (web/js/render.js) comme
-- n'importe quel autre champ de card_catalogue. Défauts = valeurs actuellement codées en dur dans
-- card.css (object-position:50% 35%, pas de zoom) : aucune carte existante ne change de rendu tant
-- qu'un modo/admin ne l'édite pas explicitement.
alter table public.card_catalogue add column if not exists image_pos_x smallint not null default 50 check (image_pos_x between 0 and 100);
alter table public.card_catalogue add column if not exists image_pos_y smallint not null default 35 check (image_pos_y between 0 and 100);
alter table public.card_catalogue add column if not exists image_scale numeric(4,2) not null default 1.00 check (image_scale between 1.00 and 3.00);

-- Parcours façon Collection/Toutes les cartes : recherche par titre, pagination, vraies cartes
-- rendues côté client via cardHTML() (toutes les colonnes qu'il consomme sont renvoyées ici).
create or replace function public.browse_catalogue_cards(p_search text default null, p_limit int default 60, p_offset int default 0)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_limit int; v_result jsonb;
begin
  perform public._require_elevated();
  v_limit := least(coalesce(p_limit, 60), 120);
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select card_id, title, platform_name, year, developer, image_url, atk, def,
           rarity, rarity_name, rarity_color, family_color,
           image_pos_x, image_pos_y, image_scale
    from public.card_catalogue
    where p_search is null or p_search = '' or title ilike '%' || p_search || '%'
    order by title asc
    limit v_limit offset p_offset
  ) t;
  return v_result;
end;
$$;

revoke execute on function public.browse_catalogue_cards(text, int, int) from public, anon;
grant execute on function public.browse_catalogue_cards(text, int, int) to authenticated;

create or replace function public.get_catalogue_card(p_card_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();
  select to_jsonb(t) into v_row from (
    select card_id, title, platform_name, year, developer, image_url, atk, def,
           rarity, rarity_name, rarity_color, family_color,
           image_pos_x, image_pos_y, image_scale
    from public.card_catalogue where card_id = p_card_id
  ) t;
  return v_row;
end;
$$;

revoke execute on function public.get_catalogue_card(text) from public, anon;
grant execute on function public.get_catalogue_card(text) to authenticated;

-- Édition complète d'une fiche catalogue — remplace replace_card_image (063) comme outil
-- principal du hub (gardé pour compat, plus utilisé par l'UI). Un seul approbateur (staff+,
-- décision actée pour l'image ; étendue ici à rareté/ATK/DEF puisque c'est le même écran).
-- Chaque paramètre nullable = "ne pas toucher à ce champ" (permet un enregistrement partiel).
create or replace function public.update_card_catalogue_entry(
  p_card_id text,
  p_image_url text default null,
  p_rarity smallint default null,
  p_atk int default null,
  p_def int default null,
  p_image_pos_x smallint default null,
  p_image_pos_y smallint default null,
  p_image_scale numeric default null,
  p_reason text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_old public.card_catalogue%rowtype;
  v_name text;
  v_color text;
begin
  perform public._require_elevated();

  select * into v_old from public.card_catalogue where card_id = p_card_id;
  if not found then
    raise exception 'Carte introuvable : %', p_card_id;
  end if;

  if p_rarity is not null then
    if p_rarity not between 0 and 5 then
      raise exception 'Rareté invalide (0 à 5).';
    end if;
    select name, color into v_name, v_color from (values
      (0::smallint, 'Commune', '#7d879c'),
      (1::smallint, 'Peu commune', '#2f9e68'),
      (2::smallint, 'Rare', '#2f74d0'),
      (3::smallint, 'Épique', '#8a45d6'),
      (4::smallint, 'Légendaire', '#d99a14'),
      (5::smallint, 'Mythique', '#e0457b')
    ) as r(rarity, name, color) where r.rarity = p_rarity;
  end if;

  update public.card_catalogue set
    image_url = coalesce(p_image_url, image_url),
    rarity = coalesce(p_rarity, rarity),
    rarity_name = coalesce(v_name, rarity_name),
    rarity_color = coalesce(v_color, rarity_color),
    atk = coalesce(p_atk, atk),
    def = coalesce(p_def, def),
    image_pos_x = coalesce(p_image_pos_x, image_pos_x),
    image_pos_y = coalesce(p_image_pos_y, image_pos_y),
    image_scale = coalesce(p_image_scale, image_scale),
    updated_at = now()
  where card_id = p_card_id;

  perform public._log_audit('edit_catalogue_card', null, p_reason, jsonb_build_object(
    'card_id', p_card_id,
    'image_url_before', v_old.image_url, 'image_url_after', p_image_url,
    'rarity_before', v_old.rarity, 'rarity_after', p_rarity,
    'atk_before', v_old.atk, 'atk_after', p_atk,
    'def_before', v_old.def, 'def_after', p_def,
    'image_pos_before', jsonb_build_object('x', v_old.image_pos_x, 'y', v_old.image_pos_y, 'scale', v_old.image_scale),
    'image_pos_after', jsonb_build_object('x', p_image_pos_x, 'y', p_image_pos_y, 'scale', p_image_scale)
  ), null);
end;
$$;

revoke execute on function public.update_card_catalogue_entry(text, text, smallint, int, int, smallint, smallint, numeric, text) from public, anon;
grant execute on function public.update_card_catalogue_entry(text, text, smallint, int, int, smallint, smallint, numeric, text) to authenticated;

-- get_next_image_review_card (064/065) : ajoute les champs nécessaires au vrai rendu cardHTML()
-- dans la file de triage (rareté/couleurs/ATK/DEF/cadrage), pas juste titre+image comme avant.
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
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

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
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
