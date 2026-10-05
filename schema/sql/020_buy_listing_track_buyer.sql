-- Ludodex Online — 020 : buy_listing() enregistre l'acheteur
-- Redéfinit la fonction créée en 014 (create or replace, sûr) pour renseigner
-- market_listings.buyer_profile_id (ajouté en 018), nécessaire au succès "Premier achat".

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
end;
$$;
