-- Ludodex Online — 047 : le correctif de 040/041 (compter puis lire à un OFFSET aléatoire) était
-- une amélioration par rapport à `ORDER BY random() LIMIT 1`, mais reste O(n) : Postgres doit
-- quand même parcourir séquentiellement les lignes jusqu'à l'offset tiré (jusqu'à ~78 000 lignes
-- pour la rareté Commune). Après la purge de 8 362 fiches à contenu adulte + les ajouts récents
-- (comblement plateforme, flops AAA), ce parcours dépasse le timeout Postgres ("canceling
-- statement due to statement timeout") à l'ouverture d'un booster — signalé par l'utilisateur.
--
-- Correctif définitif : une colonne `random_key` (valeur aléatoire figée à l'insertion, pas
-- recalculée à chaque appel) + un index sur `(rarity, random_key)`. Le tirage devient une
-- recherche par plage indexée (`WHERE rarity = X AND random_key >= seuil ORDER BY random_key
-- LIMIT 1`, avec repli en cas de dépassement de la plage) — un vrai accès O(log n), qui reste
-- rapide quelle que soit la taille du catalogue ou le volume de lignes mortes en attente de
-- VACUUM. Remplace complètement le mécanisme de comptage+offset de 040/041.

alter table public.card_catalogue add column if not exists random_key double precision not null default random();
drop index if exists public.card_catalogue_rarity_idx; -- remplacé par l'index composite ci-dessous
create index if not exists card_catalogue_rarity_random_idx on public.card_catalogue (rarity, random_key);

create or replace function public._pick_random_card(p_rarity int, p_count int default null)
returns text
language plpgsql
as $$
declare
  v_card_id text;
  v_threshold double precision := random();
begin
  select card_id into v_card_id
    from public.card_catalogue
    where rarity = p_rarity and random_key >= v_threshold
    order by random_key
    limit 1;

  if v_card_id is null then
    -- le seuil tiré dépassait la plus grande random_key de cette rareté : repli en repartant du
    -- début (équivalent d'un "wrap around"), toujours indexé.
    select card_id into v_card_id
      from public.card_catalogue
      where rarity = p_rarity
      order by random_key
      limit 1;
  end if;

  return v_card_id;
end;
$$;

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
  v_threshold double precision;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
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

    -- Tirage indexé par plage (voir 047) plutôt que comptage+offset (040/041) : exclut sa propre
    -- carte, repli en fin de plage puis repli final sur soi-même si elle est la seule de sa
    -- rareté (aucune autre ligne ne peut alors matcher `card_id <> v_card.card_id`).
    v_threshold := random();
    select card_id, title, atk, def into v_opponent
      from public.card_catalogue
      where rarity = v_card.rarity and card_id <> v_card.card_id and random_key >= v_threshold
      order by random_key
      limit 1;

    if v_opponent is null then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue
        where rarity = v_card.rarity and card_id <> v_card.card_id
        order by random_key
        limit 1;
    end if;

    if v_opponent is null then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity limit 1;
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
