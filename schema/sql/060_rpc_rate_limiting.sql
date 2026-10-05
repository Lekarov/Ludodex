-- Ludodex Online — 060 : rate limiting serveur sur les RPC sensibles (Tier 1 sécurité, voir la
-- mémoire auto-Claude ludodex_roadmap_priority).
--
-- Constat : open_booster()/run_duel() ont déjà un plafond fonctionnel (boosters_available régénéré
-- au fil du temps, duels_played_today <= 5) mais aucun garde-fou contre un client qui spamme l'appel
-- en boucle serrée (coût CPU/lock inutile même quand la réponse finale est un refus) ;
-- propose_trade() n'a AUCUN plafond — un compte peut spammer des propositions à une cible (séquestre
-- des cartes à chaque appel, inonde ses notifications). Ce fichier ajoute un throttle générique
-- réutilisable, appliqué aux trois RPC identifiées par la roadmap.
--
-- Table dédiée, jamais exposée au client (RLS activée sans policy = deny-all pour anon/authenticated,
-- seules les fonctions SECURITY DEFINER ci-dessous y touchent).
create table if not exists public.rpc_rate_limit (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  rpc_name text not null,
  window_start timestamptz not null,
  call_count int not null default 1,
  primary key (profile_id, rpc_name)
);
alter table public.rpc_rate_limit enable row level security;

-- Compteur à fenêtre glissante simple : (p_max_calls) appels max toutes les (p_window_seconds).
-- Lève une exception au-delà, sinon incrémente et laisse l'appelant continuer. `for update` sur la
-- ligne du compteur évite la course entre deux appels concurrents du même joueur.
create or replace function public._enforce_rate_limit(p_rpc text, p_max_calls int, p_window_seconds int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_now timestamptz := now();
  v_row public.rpc_rate_limit%rowtype;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_row from public.rpc_rate_limit
    where profile_id = v_profile and rpc_name = p_rpc for update;

  if not found then
    insert into public.rpc_rate_limit (profile_id, rpc_name, window_start, call_count)
      values (v_profile, p_rpc, v_now, 1);
    return;
  end if;

  if v_now - v_row.window_start > (p_window_seconds || ' seconds')::interval then
    update public.rpc_rate_limit set window_start = v_now, call_count = 1
      where profile_id = v_profile and rpc_name = p_rpc;
    return;
  end if;

  if v_row.call_count >= p_max_calls then
    raise exception 'Trop de tentatives, réessaie dans quelques instants.';
  end if;

  update public.rpc_rate_limit set call_count = call_count + 1
    where profile_id = v_profile and rpc_name = p_rpc;
end;
$$;

revoke execute on function public._enforce_rate_limit(text, int, int) from public, anon, authenticated;

-- open_booster() : reprend intégralement le corps de 059 (perf random_key + stats + régénération
-- vip/non-vip), ajoute juste l'appel au throttle en tout premier (30 appels / 60s — large marge au-
-- dessus de tout usage humain réel, coupe seulement le script qui boucle sans attendre la réponse).
create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_vip boolean;
  v_now timestamptz := now();
  v_regen_ms bigint;
  v_max_packs int;
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

  perform public._enforce_rate_limit('open_booster', 30, 60);

  select vip into v_vip from public.profiles where id = v_profile;
  v_regen_ms := case when v_vip then 3 * 60 * 1000 else 10 * 60 * 1000 end;
  v_max_packs := case when v_vip then 15 else 10 end;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

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
    v_card_id := public._pick_random_card(v_rarity, null);

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

-- run_duel() : reprend le corps de 035 à l'identique, ajoute le throttle (10 appels / 60s — le
-- plafond de 5/jour protège déjà l'économie, ça coupe juste le spam de requêtes en boucle).
create or replace function public.run_duel(p_deck text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_card_id text;
  v_card record;
  v_opponent record;
  v_my_wins integer := 0;
  v_their_wins integer := 0;
  v_rounds jsonb := '[]'::jsonb;
  v_result text;
  v_won boolean;
  v_reward integer;
  v_duel_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  perform public._enforce_rate_limit('run_duel', 10, 60);

  if p_deck is null or array_length(p_deck, 1) <> 5 then
    raise exception 'Le deck doit contenir exactement 5 cartes.';
  end if;
  if array_length(p_deck, 1) <> (select count(distinct x) from unnest(p_deck) x) then
    raise exception 'Chaque carte du deck doit être différente.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  if v_state.duel_date is distinct from current_date then
    update public.player_state set duel_date = current_date, duels_played_today = 0
      where profile_id = v_profile;
    v_state.duels_played_today := 0;
  end if;
  if v_state.duels_played_today >= 5 then
    raise exception 'Plus de duels disponibles aujourd''hui.';
  end if;

  foreach v_card_id in array p_deck loop
    if not exists (
      select 1 from public.collection
      where profile_id = v_profile and card_id = v_card_id and count > 0
    ) then
      raise exception 'Tu ne possèdes pas la carte %.', v_card_id;
    end if;

    select card_id, title, atk, def, rarity into v_card
      from public.card_catalogue where card_id = v_card_id;

    select card_id, title, atk, def into v_opponent
      from public.card_catalogue
      where rarity = v_card.rarity and card_id <> v_card.card_id
      order by random() limit 1;
    if not found then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity
        order by random() limit 1;
    end if;

    if (v_card.atk - v_opponent.def) > (v_opponent.atk - v_card.def) then
      v_result := 'win'; v_my_wins := v_my_wins + 1;
    elsif (v_opponent.atk - v_card.def) > (v_card.atk - v_opponent.def) then
      v_result := 'lose'; v_their_wins := v_their_wins + 1;
    else
      v_result := 'draw';
    end if;

    v_rounds := v_rounds || jsonb_build_object(
      'my_card_id', v_card.card_id, 'my_title', v_card.title, 'my_atk', v_card.atk,
      'opp_card_id', v_opponent.card_id, 'opp_title', v_opponent.title, 'opp_def', v_opponent.def,
      'result', v_result
    );
  end loop;

  v_won := v_my_wins > v_their_wins;
  v_reward := case when v_won then 40 + v_my_wins * 10 else round(40 * 0.25) end;

  update public.player_state set
    coins = coins + v_reward,
    duels_played_today = duels_played_today + 1,
    duel_wins_total = duel_wins_total + (case when v_won then 1 else 0 end),
    updated_at = now()
  where profile_id = v_profile;

  insert into public.duel_history (profile_id, won, my_wins, their_wins, reward, rounds)
    values (v_profile, v_won, v_my_wins, v_their_wins, v_reward, v_rounds)
    returning id into v_duel_id;

  perform public.create_notification(
    v_profile, 'duel_result',
    case when v_won then 'Duel gagné' else 'Duel perdu' end,
    v_my_wins || ' - ' || v_their_wins || ' · +' || v_reward || ' pièces.',
    'duel', v_duel_id::text
  );

  return jsonb_build_object(
    'id', v_duel_id, 'won', v_won, 'my_wins', v_my_wins, 'their_wins', v_their_wins,
    'reward', v_reward, 'rounds', v_rounds
  );
end;
$$;

-- propose_trade() : reprend le corps de 033 à l'identique, ajoute le throttle (8 appels / 300s —
-- c'est la seule des trois RPC sans plafond fonctionnel existant, donc le vrai garde-fou ici).
create or replace function public.propose_trade(p_to_profile uuid, p_offered jsonb, p_requested jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_trade_id uuid;
  v_offered_count integer;
  v_requested_count integer;
  v_from_name text;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  perform public._enforce_rate_limit('propose_trade', 8, 300);

  if p_to_profile = v_profile then
    raise exception 'Tu ne peux pas t''échanger avec toi-même.';
  end if;
  if not exists (select 1 from public.profiles where id = p_to_profile) then
    raise exception 'Joueur introuvable.';
  end if;

  select count(*) into v_offered_count from jsonb_array_elements(p_offered);
  select count(*) into v_requested_count from jsonb_array_elements(p_requested);
  if v_offered_count is null or v_offered_count < 1 or v_offered_count > 8 then
    raise exception 'Propose entre 1 et 8 cartes.';
  end if;
  if v_requested_count is null or v_requested_count < 1 or v_requested_count > 8 then
    raise exception 'Demande entre 1 et 8 cartes.';
  end if;

  perform public._trade_take_cards(v_profile, p_offered);

  insert into public.trade_offers (from_profile, to_profile, offered, requested)
    values (v_profile, p_to_profile, p_offered, p_requested)
    returning id into v_trade_id;

  select username into v_from_name from public.profiles where id = v_profile;
  perform public.create_notification(
    p_to_profile, 'trade_offer', 'Proposition d''échange',
    coalesce(v_from_name, 'Un joueur') || ' te propose un échange.',
    'trade', v_trade_id::text
  );

  return v_trade_id;
end;
$$;
