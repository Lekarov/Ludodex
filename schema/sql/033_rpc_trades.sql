-- Ludodex Online — 033 : échanges joueur-à-joueur (fonctions serveur)
-- _trade_take_cards/_trade_give_cards sont des utilitaires internes, jamais exécutables
-- directement par un client (revoke explicite) : appelées uniquement depuis les 3 fonctions
-- publiques ci-dessous, qui s'exécutent avec les droits du propriétaire (SECURITY DEFINER) donc
-- peuvent toujours les appeler malgré ce revoke.

create or replace function public._trade_take_cards(p_profile uuid, p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  v_count integer;
begin
  for item in select * from jsonb_to_recordset(p_items) as x(card_id text, shiny boolean, count integer)
  loop
    if coalesce(item.count, 1) < 1 then
      raise exception 'Quantité invalide pour %.', item.card_id;
    end if;

    select count into v_count from public.collection
      where profile_id = p_profile and card_id = item.card_id and shiny = coalesce(item.shiny, false)
      for update;
    if v_count is null or v_count < coalesce(item.count, 1) then
      raise exception 'Cartes insuffisantes : %.', item.card_id;
    end if;

    if v_count = coalesce(item.count, 1) then
      delete from public.collection
        where profile_id = p_profile and card_id = item.card_id and shiny = coalesce(item.shiny, false);
    else
      update public.collection set count = count - coalesce(item.count, 1)
        where profile_id = p_profile and card_id = item.card_id and shiny = coalesce(item.shiny, false);
    end if;
  end loop;
end;
$$;

create or replace function public._trade_give_cards(p_profile uuid, p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
begin
  for item in select * from jsonb_to_recordset(p_items) as x(card_id text, shiny boolean, count integer)
  loop
    insert into public.collection (profile_id, card_id, shiny, count)
      values (p_profile, item.card_id, coalesce(item.shiny, false), coalesce(item.count, 1))
      on conflict (profile_id, card_id, shiny)
      do update set count = public.collection.count + excluded.count;
  end loop;
end;
$$;

revoke execute on function public._trade_take_cards(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public._trade_give_cards(uuid, jsonb) from public, anon, authenticated;

create or replace function public.propose_trade(p_to_profile uuid, p_offered jsonb, p_requested jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_trade_id uuid;
  v_offered_count integer;
  v_requested_count integer;
  v_from_name text;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_to_profile = v_profile then
    raise exception 'Tu ne peux pas t''échanger avec toi-même.';
  end if;
  if not exists (select 1 from public.profiles where id = p_to_profile) then
    raise exception 'Joueur introuvable.';
  end if;

  select count(*) into v_offered_count from jsonb_array_elements(p_offered);
  select count(*) into v_requested_count from jsonb_array_elements(p_requested);
  if v_offered_count is null or v_offered_count < 1 or v_offered_count > 8 then
    raise exception 'Propose entre 1 et 8 cartes.';
  end if;
  if v_requested_count is null or v_requested_count < 1 or v_requested_count > 8 then
    raise exception 'Demande entre 1 et 8 cartes.';
  end if;

  perform public._trade_take_cards(v_profile, p_offered);

  insert into public.trade_offers (from_profile, to_profile, offered, requested)
    values (v_profile, p_to_profile, p_offered, p_requested)
    returning id into v_trade_id;

  select username into v_from_name from public.profiles where id = v_profile;
  perform public.create_notification(
    p_to_profile, 'trade_offer', 'Proposition d''échange',
    coalesce(v_from_name, 'Un joueur') || ' te propose un échange.',
    'trade', v_trade_id::text
  );

  return v_trade_id;
end;
$$;

create or replace function public.respond_trade(p_trade_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_trade public.trade_offers%rowtype;
  v_to_name text;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if not found then
    raise exception 'Proposition introuvable.';
  end if;
  if v_trade.to_profile <> v_profile then
    raise exception 'Cette proposition ne t''est pas destinée.';
  end if;
  if v_trade.status <> 'pending' then
    raise exception 'Cette proposition n''est plus en attente.';
  end if;

  select username into v_to_name from public.profiles where id = v_profile;

  if p_accept then
    perform public._trade_take_cards(v_profile, v_trade.requested);
    perform public._trade_give_cards(v_profile, v_trade.offered);
    perform public._trade_give_cards(v_trade.from_profile, v_trade.requested);
    update public.trade_offers set status = 'accepted', resolved_at = now() where id = p_trade_id;

    perform public.create_notification(
      v_trade.from_profile, 'trade_accepted', 'Échange accepté',
      coalesce(v_to_name, 'Le joueur') || ' a accepté ton échange.',
      'trade', p_trade_id::text
    );
  else
    perform public._trade_give_cards(v_trade.from_profile, v_trade.offered);
    update public.trade_offers set status = 'declined', resolved_at = now() where id = p_trade_id;

    perform public.create_notification(
      v_trade.from_profile, 'trade_declined', 'Échange refusé',
      coalesce(v_to_name, 'Le joueur') || ' a refusé ton échange.',
      'trade', p_trade_id::text
    );
  end if;
end;
$$;

create or replace function public.cancel_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_trade public.trade_offers%rowtype;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if not found then
    raise exception 'Proposition introuvable.';
  end if;
  if v_trade.from_profile <> v_profile then
    raise exception 'Cette proposition ne t''appartient pas.';
  end if;
  if v_trade.status <> 'pending' then
    raise exception 'Cette proposition n''est plus en attente.';
  end if;

  perform public._trade_give_cards(v_profile, v_trade.offered);
  update public.trade_offers set status = 'cancelled', resolved_at = now() where id = p_trade_id;
end;
$$;

revoke execute on function public.propose_trade(uuid, jsonb, jsonb) from public, anon;
revoke execute on function public.respond_trade(uuid, boolean) from public, anon;
revoke execute on function public.cancel_trade(uuid) from public, anon;
grant execute on function public.propose_trade(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.respond_trade(uuid, boolean) to authenticated;
grant execute on function public.cancel_trade(uuid) to authenticated;
