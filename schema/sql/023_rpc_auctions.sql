-- Ludodex Online — 023 : enchères (création, mise, résolution, annulation)
--
-- Pas de "pièces bloquées" en continu (contrairement au prototype) : une mise n'est validée que
-- contre le solde DISPONIBLE au moment où elle est posée. Au moment de la résolution, on revérifie
-- que le plus offrant a toujours assez de pièces ; sinon on descend à l'offre suivante, en
-- cascade, jusqu'à en trouver une valide (ou aucune). Documenté comme limite connue : un joueur
-- peut dépenser ses pièces ailleurs entre sa mise et la résolution, ce qui invalide sa propre
-- offre — plus simple à sécuriser qu'un vrai verrou de fonds pour ce v1.
--
-- Pas de résolution automatique programmée (pas de pg_cron ici) : resolve_auction() doit être
-- appelée explicitement une fois ends_at dépassé — le client (jeu.js) le fait pour chaque
-- enchère expirée qu'il affiche.

create or replace function public.create_auction_listing(p_card_id text, p_shiny boolean, p_start_price integer, p_duration_minutes integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_count integer;
  v_listing_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_start_price is null or p_start_price < 1 then
    raise exception 'La mise de départ doit être supérieure à 0.';
  end if;
  if p_duration_minutes is null or p_duration_minutes not in (30, 120, 1440) then
    raise exception 'Durée invalide.';
  end if;
  if not exists (select 1 from public.card_catalogue where card_id = p_card_id) then
    raise exception 'Carte inconnue : %.', p_card_id;
  end if;

  select count into v_count from public.collection
    where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny
    for update;
  if v_count is null or v_count < 1 then
    raise exception 'Tu ne possèdes pas cette carte.';
  end if;

  if v_count = 1 then
    delete from public.collection where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  else
    update public.collection set count = count - 1
      where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  end if;

  insert into public.market_listings (seller_type, seller_profile_id, card_id, shiny, listing_type, price, status, ends_at)
    values ('player', v_profile, p_card_id, p_shiny, 'auction', p_start_price, 'active', now() + (p_duration_minutes || ' minutes')::interval)
    returning id into v_listing_id;

  return v_listing_id;
end;
$$;

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
  v_min_next integer;
  v_bidder_coins integer;
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

  select max(amount) into v_top_bid from public.market_bids where listing_id = p_listing_id;
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
end;
$$;

create or replace function public.cancel_auction_listing(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.seller_type <> 'player' or v_listing.seller_profile_id <> v_profile then
    raise exception 'Cette annonce ne t''appartient pas.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette annonce n''est plus active.';
  end if;
  if exists (select 1 from public.market_bids where listing_id = p_listing_id) then
    raise exception 'Impossible d''annuler : des enchères ont déjà été placées.';
  end if;

  update public.market_listings set status = 'cancelled' where id = p_listing_id;

  insert into public.collection (profile_id, card_id, shiny, count)
    values (v_profile, v_listing.card_id, v_listing.shiny, 1)
    on conflict (profile_id, card_id, shiny)
    do update set count = public.collection.count + 1;
end;
$$;

-- Callable par n'importe quel joueur authentifié (pas seulement le vendeur) : ne fait que
-- constater un résultat déjà déterminé par les mises existantes, aucune valeur fournie par
-- l'appelant n'influence le résultat.
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

revoke execute on function public.create_auction_listing(text, boolean, integer, integer) from public, anon;
revoke execute on function public.place_bid(uuid, integer) from public, anon;
revoke execute on function public.cancel_auction_listing(uuid) from public, anon;
revoke execute on function public.resolve_auction(uuid) from public, anon;
grant execute on function public.create_auction_listing(text, boolean, integer, integer) to authenticated;
grant execute on function public.place_bid(uuid, integer) to authenticated;
grant execute on function public.cancel_auction_listing(uuid) to authenticated;
grant execute on function public.resolve_auction(uuid) to authenticated;
