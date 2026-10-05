-- Ludodex Online — 058 : statut VIP (régénération de boosters accélérée) + badge de grade sur le
-- profil (Fondateur/Modérateur/Admin/VIP). Nécessite que 057_founder_role_enum.sql ait déjà
-- tourné seul avant celui-ci (valeur 'fondateur' de profile_role).
--
-- `vip` est un simple booléen, DÉCORRÉLÉ de `role` : `role` reste la hiérarchie de permissions
-- (player/vip/moderator/admin/fondateur — moderator/admin/fondateur donnent accès à la
-- modération des signalements), alors que `vip` est un pur avantage de gameplay (régénération de
-- boosters) qui peut s'appliquer à n'importe quel rôle (ex. un modérateur qui est aussi VIP).

alter table public.profiles add column if not exists vip boolean not null default false;

-- Le joueur ne peut modifier ni son rôle ni son statut VIP lui-même (étend
-- prevent_role_self_escalation, 002_profiles.sql, au nouveau champ).
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
as $$
begin
  if (new.role is distinct from old.role or new.vip is distinct from old.vip) and auth.uid() = old.id then
    raise exception 'Le rôle et le statut VIP ne peuvent pas être modifiés par le joueur lui-même.';
  end if;
  return new;
end;
$$;

-- La modération des signalements (007_messages_and_moderation.sql) reste ouverte à modérateur ET
-- admin ; un fondateur doit avoir au moins les mêmes droits.
drop policy if exists "message_reports_select_own_or_moderation" on public.message_reports;
create policy "message_reports_select_own_or_moderation"
  on public.message_reports for select
  using (
    auth.uid() = reporter_id
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('moderator', 'admin', 'fondateur')
    )
  );

drop policy if exists "message_reports_update_moderation_only" on public.message_reports;
create policy "message_reports_update_moderation_only"
  on public.message_reports for update
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('moderator', 'admin', 'fondateur')
    )
  );

-- open_booster() (010_rpc_open_booster.sql) : régénération 1/10min plafonnée à 10 pour un joueur
-- normal, 1/3min plafonnée à 15 pour un compte VIP — seule différence avec la version 010/019.
create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_vip boolean;
  v_now timestamptz := now();
  v_regen_ms bigint;
  v_max_packs int;
  v_gold_every constant int := 10;              -- GOLD_EVERY
  v_shiny_rate constant numeric := 1.0 / 20;    -- SHINY_RATE
  v_gained bigint;
  v_gold boolean;
  v_weights numeric[];
  v_results jsonb := '[]'::jsonb;
  v_card_id text;
  v_rarity int;
  v_shiny boolean;
  s int;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select vip into v_vip from public.profiles where id = v_profile;
  v_regen_ms := case when v_vip then 3 * 60 * 1000 else 10 * 60 * 1000 end;
  v_max_packs := case when v_vip then 15 else 10 end;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  -- Régénération, identique à regen() côté client.
  if v_state.boosters_available < v_max_packs then
    v_gained := floor(extract(epoch from (v_now - v_state.last_regen_at)) * 1000 / v_regen_ms);
    if v_gained > 0 then
      v_state.boosters_available := least(v_max_packs, v_state.boosters_available + v_gained);
      if v_state.boosters_available >= v_max_packs then
        v_state.last_regen_at := v_now;
      else
        v_state.last_regen_at := v_state.last_regen_at + (v_gained * v_regen_ms) * interval '1 millisecond';
      end if;
    end if;
  else
    v_state.last_regen_at := v_now;
  end if;

  if v_state.boosters_available < 1 then
    update public.player_state
      set last_regen_at = v_state.last_regen_at, updated_at = v_now
      where profile_id = v_profile;
    raise exception 'Aucun booster disponible.';
  end if;

  v_gold := v_state.opens_since_gold >= (v_gold_every - 1);
  v_state.boosters_available := v_state.boosters_available - 1;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);

    select card_id into v_card_id
      from public.card_catalogue
      where rarity = v_rarity
      order by random()
      limit 1;

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;

    insert into public.collection (profile_id, card_id, shiny, count)
      values (v_profile, v_card_id, v_shiny, 1)
      on conflict (profile_id, card_id, shiny)
      do update set count = public.collection.count + 1;

    v_results := v_results || jsonb_build_object('card_id', v_card_id, 'rarity', v_rarity, 'shiny', v_shiny);
  end loop;

  if v_gold then
    v_state.opens_since_gold := 0;
  else
    v_state.opens_since_gold := v_state.opens_since_gold + 1;
  end if;

  update public.player_state
    set boosters_available = v_state.boosters_available,
        last_regen_at = v_state.last_regen_at,
        opens_since_gold = v_state.opens_since_gold,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;
