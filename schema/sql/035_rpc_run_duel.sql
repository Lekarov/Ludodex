-- Ludodex Online — 035 : run_duel() — résout un duel de 5 cartes contre l'ordinateur
-- Reproduit site/js/engine social.js (runDuel/pickOpponentFor) : chaque carte du deck du joueur
-- affronte une carte adverse tirée au hasard dans card_catalogue à la MÊME rareté, ATK contre DEF
-- dans les deux sens, la marge la plus élevée gagne la manche. Récompense identique à la démo :
-- 40 + 10 par manche gagnée si victoire globale, sinon 10 (25 % de consolation).

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

revoke execute on function public.run_duel(text[]) from public, anon;
grant execute on function public.run_duel(text[]) to authenticated;
