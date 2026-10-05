-- Ludodex Online — 014 : marché, vente directe joueur-à-joueur (create/cancel/buy)
--
-- PÉRIMÈTRE VOLONTAIREMENT RÉDUIT : seul le type d'annonce "sale" (vente à prix fixe) est
-- implémenté ici. Les enchères ("auction") existent dans le schéma (006_market.sql,
-- market_bids) mais pas encore de RPC : une vraie enchère a besoin d'une date de fin, d'une
-- résolution différée (qui gagne quand ça se termine, avec des pièces qui restaient
-- "disponibles" jusque-là) et d'un mécanisme qui déclenche cette résolution (cron ou appel
-- explicite) — ça mérite sa propre passe de conception, pas un ajout rapide. Les bots du
-- marché (voir cadrage) ne sont pas non plus implémentés : pour l'instant le marché est
-- exclusivement joueur-à-joueur, avec zéro annonce tant que personne n'en crée.
--
-- Commission 0 % (FEE=0 dans le prototype) : l'acheteur paie exactement le prix affiché, le
-- vendeur reçoit exactement ce montant.
--
-- Modèle retenu : mettre une carte en vente la RETIRE immédiatement de la collection du
-- vendeur (déposée en "séquestre" dans l'annonce) ; annuler ou vendre la restitue au vendeur
-- ou la transfère à l'acheteur. Évite qu'une carte mise en vente soit revendue ou défaussée
-- deux fois pendant qu'elle est listée.

create or replace function public.create_sale_listing(p_card_id text, p_shiny boolean, p_price integer)
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
  if p_price is null or p_price < 1 then
    raise exception 'Le prix doit être supérieur à 0.';
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

  insert into public.market_listings (seller_type, seller_profile_id, card_id, shiny, listing_type, price, status)
    values ('player', v_profile, p_card_id, p_shiny, 'sale', p_price, 'active')
    returning id into v_listing_id;

  return v_listing_id;
end;
$$;

create or replace function public.cancel_sale_listing(p_listing_id uuid)
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

  update public.market_listings set status = 'cancelled' where id = p_listing_id;

  insert into public.collection (profile_id, card_id, shiny, count)
    values (v_profile, v_listing.card_id, v_listing.shiny, 1)
    on conflict (profile_id, card_id, shiny)
    do update set count = public.collection.count + 1;
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

  update public.market_listings set status = 'sold' where id = p_listing_id;

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
end;
$$;

revoke execute on function public.create_sale_listing(text, boolean, integer) from public, anon;
revoke execute on function public.cancel_sale_listing(uuid) from public, anon;
revoke execute on function public.buy_listing(uuid) from public, anon;
grant execute on function public.create_sale_listing(text, boolean, integer) to authenticated;
grant execute on function public.cancel_sale_listing(uuid) to authenticated;
grant execute on function public.buy_listing(uuid) to authenticated;
