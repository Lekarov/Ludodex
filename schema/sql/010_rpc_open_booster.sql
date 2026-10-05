-- Ludodex Online — 010 : fonction serveur open_booster()
-- Seule façon d'ajouter des cartes à une collection par ouverture de booster : le client ne
-- peut ni choisir la carte, ni la rareté, ni le stock restant. Logique copiée à l'identique de
-- site/js/engine/packs.js + site/js/config/constants.js (régénération 1/10 min, stock max 10,
-- 10e booster doré, poids de rareté par emplacement, 5 % de brillante) pour que le comportement
-- reste cohérent avec le prototype si un jour il se connecte à ce backend.
--
-- LIMITE CONNUE : le tirage d'une carte au hasard dans card_catalogue utilise
-- `order by random() limit 1`, donc un scan complet de la tranche de rareté à chaque carte
-- tirée (jusqu'à ~13000 lignes pour "Commune"). Largement suffisant pour un trafic de hobby sur
-- un compute nano ; à revoir seulement si ça devient un vrai goulot d'étranglement.

create or replace function public.pick_weighted_rarity(weights numeric[])
returns int
language plpgsql
as $$
declare
  total numeric := 0;
  x numeric;
  i int;
begin
  for i in 1..array_length(weights, 1) loop
    total := total + weights[i];
  end loop;
  x := random() * total;
  for i in 1..array_length(weights, 1) loop
    x := x - weights[i];
    if x < 0 then
      return i - 1; -- rareté 0-based (0 = Commune ... 5 = Mythique)
    end if;
  end loop;
  return array_length(weights, 1) - 1;
end;
$$;

revoke execute on function public.pick_weighted_rarity(numeric[]) from public, anon, authenticated;

create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_now timestamptz := now();
  v_regen_ms constant bigint := 10 * 60 * 1000; -- REGEN_MS
  v_max_packs constant int := 10;               -- MAX_PACKS
  v_gold_every constant int := 10;              -- GOLD_EVERY
  v_shiny_rate constant numeric := 1.0 / 20;    -- SHINY_RATE
  v_gained bigint;
  v_gold boolean;
  v_weights numeric[];
  v_results jsonb := '[]'::jsonb;
  v_card_id text;
  v_rarity int;
  v_shiny boolean;
  s int;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  -- Régénération, identique à regen() côté client.
  if v_state.boosters_available < v_max_packs then
    v_gained := floor(extract(epoch from (v_now - v_state.last_regen_at)) * 1000 / v_regen_ms);
    if v_gained > 0 then
      v_state.boosters_available := least(v_max_packs, v_state.boosters_available + v_gained);
      if v_state.boosters_available >= v_max_packs then
        v_state.last_regen_at := v_now;
      else
        v_state.last_regen_at := v_state.last_regen_at + (v_gained * v_regen_ms) * interval '1 millisecond';
      end if;
    end if;
  else
    v_state.last_regen_at := v_now;
  end if;

  if v_state.boosters_available < 1 then
    update public.player_state
      set last_regen_at = v_state.last_regen_at, updated_at = v_now
      where profile_id = v_profile;
    raise exception 'Aucun booster disponible.';
  end if;

  v_gold := v_state.opens_since_gold >= (v_gold_every - 1);
  v_state.boosters_available := v_state.boosters_available - 1;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);

    select card_id into v_card_id
      from public.card_catalogue
      where rarity = v_rarity
      order by random()
      limit 1;

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;

    insert into public.collection (profile_id, card_id, shiny, count)
      values (v_profile, v_card_id, v_shiny, 1)
      on conflict (profile_id, card_id, shiny)
      do update set count = public.collection.count + 1;

    v_results := v_results || jsonb_build_object('card_id', v_card_id, 'rarity', v_rarity, 'shiny', v_shiny);
  end loop;

  if v_gold then
    v_state.opens_since_gold := 0;
  else
    v_state.opens_since_gold := v_state.opens_since_gold + 1;
  end if;

  update public.player_state
    set boosters_available = v_state.boosters_available,
        last_regen_at = v_state.last_regen_at,
        opens_since_gold = v_state.opens_since_gold,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;

revoke execute on function public.open_booster() from public, anon;
grant execute on function public.open_booster() to authenticated;
