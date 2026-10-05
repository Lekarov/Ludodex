-- Ludodex Online — 030 : notifications déclenchées par le marché et les succès
-- Redéfinit (create or replace, sûr) place_bid/resolve_auction/buy_listing (023/020) et
-- sync_and_claim_achievements (021) pour appeler create_notification (029) aux moments utiles :
-- mise dépassée, enchère gagnée, carte vendue (vente directe ou enchère), succès débloqué.
-- link_type='listing' → le client ouvre listing.html?id=<link_id> (page de détail d'une annonce,
-- garde l'historique complet des mises indéfiniment) ; link_type='achievement' → achievements.html.

create or replace function public.place_bid(p_listing_id uuid, p_amount integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
  v_top_bid integer;
  v_top_bidder uuid;
  v_min_next integer;
  v_bidder_coins integer;
  v_title text;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.listing_type <> 'auction' then
    raise exception 'Cette annonce n''est pas une enchère.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette enchère n''est plus active.';
  end if;
  if v_listing.ends_at <= now() then
    raise exception 'Cette enchère est terminée.';
  end if;
  if v_listing.seller_type = 'player' and v_listing.seller_profile_id = v_profile then
    raise exception 'Tu ne peux pas enchérir sur ta propre annonce.';
  end if;

  select amount, bidder_profile_id into v_top_bid, v_top_bidder
    from public.market_bids where listing_id = p_listing_id order by amount desc limit 1;
  v_min_next := coalesce(v_top_bid + greatest(1, round(v_top_bid * 0.07)), v_listing.price);
  if p_amount < v_min_next then
    raise exception 'Mise minimale : %.', v_min_next;
  end if;

  select coins into v_bidder_coins from public.player_state where profile_id = v_profile;
  if v_bidder_coins is null or v_bidder_coins < p_amount then
    raise exception 'Pas assez de pièces pour cette mise.';
  end if;

  insert into public.market_bids (listing_id, bidder_type, bidder_profile_id, amount)
    values (p_listing_id, 'player', v_profile, p_amount);

  if v_top_bidder is not null and v_top_bidder <> v_profile then
    select title into v_title from public.card_catalogue where card_id = v_listing.card_id;
    perform public.create_notification(
      v_top_bidder, 'outbid', 'Mise dépassée',
      coalesce(v_title, 'Une carte') || ' : quelqu''un a misé plus haut que toi (' || p_amount || ' pièces).',
      'listing', p_listing_id::text
    );
  end if;
end;
$$;

create or replace function public.resolve_auction(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.market_listings%rowtype;
  v_bid record;
  v_winner_coins integer;
  v_resolved boolean := false;
  v_title text;
begin
  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.listing_type <> 'auction' or v_listing.status <> 'active' then
    return; -- déjà résolue ou n'est pas une enchère : rien à faire, pas une erreur
  end if;
  if v_listing.ends_at > now() then
    raise exception 'Cette enchère n''est pas encore terminée.';
  end if;

  select title into v_title from public.card_catalogue where card_id = v_listing.card_id;

  for v_bid in
    select * from public.market_bids
    where listing_id = p_listing_id
    order by amount desc, created_at asc
  loop
    select coins into v_winner_coins from public.player_state where profile_id = v_bid.bidder_profile_id for update;
    if v_winner_coins is not null and v_winner_coins >= v_bid.amount then
      update public.market_listings set status = 'sold', buyer_profile_id = v_bid.bidder_profile_id where id = p_listing_id;
      update public.player_state set coins = coins - v_bid.amount, updated_at = now() where profile_id = v_bid.bidder_profile_id;
      if v_listing.seller_type = 'player' then
        update public.player_state set coins = coins + v_bid.amount, updated_at = now() where profile_id = v_listing.seller_profile_id;
      end if;
      insert into public.collection (profile_id, card_id, shiny, count)
        values (v_bid.bidder_profile_id, v_listing.card_id, v_listing.shiny, 1)
        on conflict (profile_id, card_id, shiny)
        do update set count = public.collection.count + 1;

      perform public.create_notification(
        v_bid.bidder_profile_id, 'auction_won', 'Enchère remportée',
        'Tu as remporté ' || coalesce(v_title, 'une carte') || ' pour ' || v_bid.amount || ' pièces.',
        'listing', p_listing_id::text
      );
      if v_listing.seller_type = 'player' then
        perform public.create_notification(
          v_listing.seller_profile_id, 'listing_sold', 'Carte vendue',
          coalesce(v_title, 'Ta carte') || ' s''est vendue aux enchères pour ' || v_bid.amount || ' pièces.',
          'listing', p_listing_id::text
        );
      end if;

      v_resolved := true;
      exit;
    end if;
  end loop;

  if not v_resolved then
    -- Aucune offre valide (ou aucune offre du tout) : la carte revient au vendeur.
    update public.market_listings set status = 'cancelled' where id = p_listing_id;
    if v_listing.seller_type = 'player' then
      insert into public.collection (profile_id, card_id, shiny, count)
        values (v_listing.seller_profile_id, v_listing.card_id, v_listing.shiny, 1)
        on conflict (profile_id, card_id, shiny)
        do update set count = public.collection.count + 1;
    end if;
  end if;
end;
$$;

create or replace function public.buy_listing(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
  v_buyer_coins integer;
  v_title text;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette annonce n''est plus disponible.';
  end if;
  if v_listing.listing_type <> 'sale' then
    raise exception 'Cette annonce n''est pas une vente directe.';
  end if;
  if v_listing.seller_type = 'player' and v_listing.seller_profile_id = v_profile then
    raise exception 'Tu ne peux pas acheter ta propre annonce.';
  end if;

  select coins into v_buyer_coins from public.player_state where profile_id = v_profile for update;
  if v_buyer_coins is null or v_buyer_coins < v_listing.price then
    raise exception 'Pas assez de pièces.';
  end if;

  update public.market_listings set status = 'sold', buyer_profile_id = v_profile where id = p_listing_id;

  update public.player_state set coins = coins - v_listing.price, updated_at = now()
    where profile_id = v_profile;

  if v_listing.seller_type = 'player' then
    update public.player_state set coins = coins + v_listing.price, updated_at = now()
      where profile_id = v_listing.seller_profile_id;
  end if;

  insert into public.collection (profile_id, card_id, shiny, count)
    values (v_profile, v_listing.card_id, v_listing.shiny, 1)
    on conflict (profile_id, card_id, shiny)
    do update set count = public.collection.count + 1;

  if v_listing.seller_type = 'player' then
    select title into v_title from public.card_catalogue where card_id = v_listing.card_id;
    perform public.create_notification(
      v_listing.seller_profile_id, 'listing_sold', 'Carte vendue',
      coalesce(v_title, 'Ta carte') || ' s''est vendue pour ' || v_listing.price || ' pièces.',
      'listing', p_listing_id::text
    );
  end if;
end;
$$;

create or replace function public.sync_and_claim_achievements()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_owned_distinct integer;
  v_catalogue_total integer;
  v_platforms_completed integer;
  v_sold_count integer;
  v_bought_count integer;
  v_earned integer;
  v_total_reward integer := 0;
  v_granted jsonb := '[]'::jsonb;
  rec record;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  select count(distinct card_id) into v_owned_distinct from public.collection where profile_id = v_profile;
  select count(*) into v_catalogue_total from public.card_catalogue;
  select count(*) into v_sold_count from public.market_listings where seller_profile_id = v_profile and status = 'sold';
  select count(*) into v_bought_count from public.market_listings where buyer_profile_id = v_profile and status = 'sold';
  select coalesce(sum(price), 0) into v_earned from public.market_listings where seller_profile_id = v_profile and status = 'sold';

  select count(*) into v_platforms_completed from (
    select cc.platform_name
    from public.card_catalogue cc
    group by cc.platform_name
    having count(*) = (
      select count(*)
      from public.collection c
      join public.card_catalogue cc2 on cc2.card_id = c.card_id
      where c.profile_id = v_profile and cc2.platform_name = cc.platform_name
    )
  ) done_platforms;

  -- Déblocage : toute définition dont la valeur atteint l'objectif et pas encore enregistrée.
  with defs(achievement_id, val, goal) as (
    values
      ('b1',   v_state.boosters_opened_total, 1),
      ('b10',  v_state.boosters_opened_total, 10),
      ('b50',  v_state.boosters_opened_total, 50),
      ('b100', v_state.boosters_opened_total, 100),
      ('b250', v_state.boosters_opened_total, 250),
      ('gold', v_state.golds_opened_total, 1),
      ('c10',  v_owned_distinct, 10),
      ('c25',  v_owned_distinct, 25),
      ('c50',  v_owned_distinct, 50),
      ('c100', v_owned_distinct, 100),
      ('call', v_owned_distinct, v_catalogue_total),
      ('set1', v_platforms_completed, 1),
      ('set5', v_platforms_completed, 5),
      ('r2',   v_state.pulls_rare, 1),
      ('r3',   v_state.pulls_epic, 1),
      ('r4',   v_state.pulls_legendary, 1),
      ('r5',   v_state.pulls_mythic, 1),
      ('sh1',  v_state.shiny_drawn_total, 1),
      ('sh5',  v_state.shiny_drawn_total, 5),
      ('m1',   v_bought_count, 1),
      ('m2',   v_sold_count, 1),
      ('m10',  v_sold_count, 10),
      ('earn', v_earned, 1000),
      ('raf',  0, 1), -- tombola pas encore implémentée : jamais atteint
      ('win',  0, 1)  -- enchères pas encore implémentées : jamais atteint
  )
  insert into public.achievements_unlocked (profile_id, achievement_id)
  select v_profile, achievement_id from defs where val >= goal
  on conflict (profile_id, achievement_id) do nothing;

  -- Récupération : verse la récompense de chaque succès débloqué pas encore payé, et notifie.
  for rec in
    with rewards(achievement_id, reward) as (
      values
        ('b1', 10), ('b10', 25), ('b50', 60), ('b100', 100), ('b250', 150),
        ('gold', 20), ('c10', 20), ('c25', 40), ('c50', 80), ('c100', 150), ('call', 300),
        ('set1', 60), ('set5', 150),
        ('r2', 15), ('r3', 30), ('r4', 60), ('r5', 120),
        ('sh1', 40), ('sh5', 100),
        ('m1', 10), ('m2', 15), ('m10', 50), ('earn', 75),
        ('raf', 20), ('win', 25)
    )
    update public.achievements_unlocked au
      set reward_granted = true, reward_granted_at = now()
      from rewards r
      where au.profile_id = v_profile
        and au.achievement_id = r.achievement_id
        and au.reward_granted = false
      returning au.achievement_id, r.reward
  loop
    v_total_reward := v_total_reward + rec.reward;
    v_granted := v_granted || jsonb_build_object('achievement_id', rec.achievement_id, 'reward', rec.reward);
    perform public.create_notification(
      v_profile, 'achievement', 'Succès débloqué',
      'Récompense : ' || rec.reward || ' pièces.',
      'achievement', rec.achievement_id
    );
  end loop;

  if v_total_reward > 0 then
    update public.player_state set coins = coins + v_total_reward, updated_at = now() where profile_id = v_profile;
  end if;

  return jsonb_build_object('granted', v_granted, 'total_reward', v_total_reward);
end;
$$;
