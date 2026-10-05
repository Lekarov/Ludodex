-- Ludodex Online — 038 : notification "carte de ta liste de souhaits mise en vente"
-- Déclenché à la création d'une annonce (vente directe OU enchère — les deux passent par un
-- insert dans market_listings, voir 014/023). Un joueur peut être notifié plusieurs fois pour la
-- même carte si plusieurs exemplaires sont mis en vente au fil du temps — voulu ("recevez une
-- alerte si cette carte est mise en vente"), pas de suppression automatique de la liste.

create or replace function public.notify_wishlist_on_listing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
  wl record;
begin
  select title into v_title from public.card_catalogue where card_id = new.card_id;

  for wl in
    select profile_id from public.wishlist
    where card_id = new.card_id
      and profile_id is distinct from new.seller_profile_id
  loop
    perform public.create_notification(
      wl.profile_id, 'wishlist_available', 'Carte de ta liste de souhaits en vente',
      coalesce(v_title, 'Une carte') || ' vient d''être mise en vente sur le marché.',
      'listing', new.id::text
    );
  end loop;

  return new;
end;
$$;

drop trigger if exists trg_notify_wishlist_on_listing on public.market_listings;
create trigger trg_notify_wishlist_on_listing
  after insert on public.market_listings
  for each row execute function public.notify_wishlist_on_listing();
