-- Ludodex Online — 013 : fonction serveur discard_card()
-- Défausse une carte possédée contre des pièces. Valeur = 30 % d'une valeur de référence par
-- rareté (REF_BASE dans site/js/config/constants.js), arrondie, minimum 1.
--
-- SIMPLIFICATION ASSUMÉE : le prototype fait varier la valeur de référence dans une fourchette
-- de ±20 % selon le score de prestige exact du jeu (voir ref() dans site/js/engine/market.js).
-- Reproduire cette variance côté serveur demanderait de stocker ce score par carte (colonne
-- supplémentaire sur card_catalogue, régénérée à chaque changement de catalogue). Pour l'instant,
-- la valeur de référence est fixe par rareté : perd la variance fine, garde l'ordre de grandeur.
-- À revoir si cette précision devient importante.

create or replace function public.discard_card(p_card_id text, p_shiny boolean)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_rarity int;
  v_ref_base constant integer[] := array[10, 25, 60, 150, 400, 1200]; -- REF_BASE, index = rareté
  v_discard_rate constant numeric := 0.3;
  v_shiny_mult constant integer := 3;
  v_value integer;
  v_count integer;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select rarity into v_rarity from public.card_catalogue where card_id = p_card_id;
  if v_rarity is null then
    raise exception 'Carte inconnue : %.', p_card_id;
  end if;

  select count into v_count from public.collection
    where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny
    for update;
  if v_count is null or v_count < 1 then
    raise exception 'Tu ne possèdes pas cette carte.';
  end if;

  v_value := greatest(1, round(v_ref_base[v_rarity + 1] * v_discard_rate * (case when p_shiny then v_shiny_mult else 1 end)));

  if v_count = 1 then
    delete from public.collection where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  else
    update public.collection set count = count - 1
      where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  end if;

  update public.player_state set coins = coins + v_value, updated_at = now() where profile_id = v_profile;

  return v_value;
end;
$$;

revoke execute on function public.discard_card(text, boolean) from public, anon;
grant execute on function public.discard_card(text, boolean) to authenticated;
