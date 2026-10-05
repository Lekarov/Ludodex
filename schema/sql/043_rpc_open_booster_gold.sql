-- Ludodex Online — 043 : chance infime de carte Gold unique à l'ouverture d'un booster
-- Redéfinit open_booster() (040) pour ajouter, APRÈS les 5 cartes normales (ne remplace aucun
-- tirage existant, ne touche pas aux poids de rareté), une chance bonus ultra faible de
-- remporter une carte Gold : un jeu console (PC/Mac/Linux/mobile/web/VR/cloud exclus, voir
-- v_console_exclusions) tiré parmi ceux qui n'ont PAS ENCORE de propriétaire Gold
-- (public.gold_claims, 042). Taux volontairement "de fou" (v_gold_rate) : bien plus bas que
-- Mythique (2 % par carte). Si deux joueurs déclenchent ce tirage à la même microseconde pour le
-- même jeu, la clé primaire de gold_claims tranche : le second reçoit une exception
-- unique_violation, silencieusement absorbée (pas de carte Gold ce tirage-ci pour lui, aucune
-- erreur visible côté client — un booster ne doit jamais échouer à cause d'un bonus raté).

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
  v_gold_every constant int := 10;              -- GOLD_EVERY (booster doré, sans rapport avec Gold unique)
  v_shiny_rate constant numeric := 1.0 / 20;    -- SHINY_RATE
  v_gold_rate constant numeric := 1.0 / 20000;  -- taux d'une carte Gold UNIQUE par booster ouvert
  v_gained bigint;
  v_gold boolean;
  v_weights numeric[];
  v_results jsonb := '[]'::jsonb;
  v_card_id text;
  v_rarity int;
  v_shiny boolean;
  s int;
  v_rarity_counts int[] := array[null, null, null, null, null, null];
  v_rarity_count int;
  v_gold_card_id text;
  v_gold_title text;
  v_console_exclusions constant text[] := array[
    'PC (Microsoft Windows)', 'Mac', 'Linux', 'DOS',
    'iOS', 'Android', 'Windows Phone', 'BlackBerry OS', 'Legacy Mobile Device', 'Windows Mobile',
    'Web browser',
    'SteamVR', 'Oculus Rift', 'Oculus VR', 'Oculus Quest', 'Oculus Go', 'PlayStation VR',
    'PlayStation VR2', 'Windows Mixed Reality', 'Meta Quest 2', 'Meta Quest 3', 'Gear VR',
    'Daydream', 'visionOS',
    'Google Stadia', 'OnLive Game System', 'Amazon Fire TV', 'Ouya',
    'DVD Player', 'Blu-ray Player', 'Palm OS', 'PLATO', 'Digiblast', 'Legacy Computer'
  ];
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
  v_state.boosters_opened_total := v_state.boosters_opened_total + 1;
  if v_gold then
    v_state.golds_opened_total := v_state.golds_opened_total + 1;
  end if;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);

    if v_rarity_counts[v_rarity + 1] is null then
      select count(*) into v_rarity_count from public.card_catalogue where rarity = v_rarity;
      v_rarity_counts[v_rarity + 1] := v_rarity_count;
    end if;

    v_card_id := public._pick_random_card(v_rarity, v_rarity_counts[v_rarity + 1]);

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;
    if v_shiny then
      v_state.shiny_drawn_total := v_state.shiny_drawn_total + 1;
    end if;
    if v_rarity = 2 then v_state.pulls_rare := v_state.pulls_rare + 1;
    elsif v_rarity = 3 then v_state.pulls_epic := v_state.pulls_epic + 1;
    elsif v_rarity = 4 then v_state.pulls_legendary := v_state.pulls_legendary + 1;
    elsif v_rarity = 5 then v_state.pulls_mythic := v_state.pulls_mythic + 1;
    end if;

    insert into public.collection (profile_id, card_id, shiny, count)
      values (v_profile, v_card_id, v_shiny, 1)
      on conflict (profile_id, card_id, shiny)
      do update set count = public.collection.count + 1;

    v_results := v_results || jsonb_build_object('card_id', v_card_id, 'rarity', v_rarity, 'shiny', v_shiny);
  end loop;

  -- Bonus Gold unique : indépendant des 5 cartes ci-dessus, ne consomme aucun slot.
  if random() < v_gold_rate then
    select card_id into v_gold_card_id
      from public.card_catalogue
      where platform_name <> all (v_console_exclusions)
        and card_id not in (select card_id from public.gold_claims)
      order by random()
      limit 1;

    if v_gold_card_id is not null then
      begin
        insert into public.gold_claims (card_id, profile_id) values (v_gold_card_id, v_profile);
        select title into v_gold_title from public.card_catalogue where card_id = v_gold_card_id;
        v_results := v_results || jsonb_build_object('card_id', v_gold_card_id, 'gold', true);
        perform public.create_notification(
          v_profile, 'gold_unique', '✨ Carte Gold unique !',
          'Tu es désormais le seul possesseur de ' || coalesce(v_gold_title, 'cette carte') || ' dans tout Ludodex.',
          null, null
        );
      exception when unique_violation then
        -- Un autre joueur l'a obtenue à la même microseconde : rien pour ce tirage-ci, pas d'erreur.
        null;
      end;
    end if;
  end if;

  if v_gold then
    v_state.opens_since_gold := 0;
  else
    v_state.opens_since_gold := v_state.opens_since_gold + 1;
  end if;

  update public.player_state
    set boosters_available = v_state.boosters_available,
        last_regen_at = v_state.last_regen_at,
        opens_since_gold = v_state.opens_since_gold,
        boosters_opened_total = v_state.boosters_opened_total,
        golds_opened_total = v_state.golds_opened_total,
        shiny_drawn_total = v_state.shiny_drawn_total,
        pulls_rare = v_state.pulls_rare,
        pulls_epic = v_state.pulls_epic,
        pulls_legendary = v_state.pulls_legendary,
        pulls_mythic = v_state.pulls_mythic,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;
