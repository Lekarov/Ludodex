-- Ludodex Online — 011 : suppression de compte en libre-service (droit à l'oubli RGPD)
-- Le joueur ne peut supprimer que SON PROPRE compte (auth.uid(), jamais un id fourni par le
-- client). Supprime la ligne dans auth.users : toutes les tables applicatives (profiles,
-- player_state, collection, achievements_unlocked, market_listings/bids côté vendeur/acheteur
-- joueur, private_messages, message_reports, blocks) ont une contrainte
-- `references public.profiles(id) on delete cascade`, donc tout disparaît en cascade en une
-- seule transaction. Les tables internes de Supabase Auth (identities, sessions,
-- refresh_tokens) ont elles-mêmes des clés étrangères en cascade vers auth.users.
--
-- LIMITE CONNUE : les annonces de marché où ce joueur était vendeur/acheteur disparaissent avec
-- lui (cascade), ce qui peut laisser une enchère en cours sans vendeur si un joueur supprime son
-- compte pendant une enchère active. Pas de garde-fou pour l'instant (cas rare, à traiter plus
-- tard si besoin — ex. interdire la suppression avec une annonce active).

create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  delete from auth.users where id = v_profile;
end;
$$;

revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
