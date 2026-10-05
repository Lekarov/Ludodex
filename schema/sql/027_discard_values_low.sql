-- Ludodex Online — 027 : valeurs de défausse très basses, uniques par rareté
-- Remplace le barème de 013_rpc_discard_card.sql (30 % d'une valeur de référence, jusqu'à 360
-- pièces pour une Mythique, 1080 en brillante) : trop rentable, ça incitait à défausser plutôt
-- qu'à garder pour la collection ou à mettre aux enchères. Décision prise avec l'utilisateur :
-- barème volontairement quasi plat, qui part de 1 pièce pour la rareté la plus commune et
-- n'augmente que très légèrement avec la rareté (pas proportionnel à la valeur de la carte).
--
-- create or replace function : redéfinit la fonction créée en 013, aucune autre partie du
-- fichier (vérifications, transfert de carte, mise à jour des pièces) ne change.

create or replace function public.discard_card(p_card_id text, p_shiny boolean)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_rarity int;
  -- Valeur de défausse par rareté (index = rareté, 0=Commune..5=Mythique) : quasi plate, décidée
  -- avec l'utilisateur pour ne jamais concurrencer la collection ou le marché.
  v_discard_value constant integer[] := array[1, 2, 3, 4, 6, 9];
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

  v_value := v_discard_value[v_rarity + 1] * (case when p_shiny then v_shiny_mult else 1 end);

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
