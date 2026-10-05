-- Ludodex Online — 025 : boosters thématiques
-- Repris de site/js/engine/raffle.js (THEMES) : 10 thèmes (6 familles de plateformes + 4
-- décennies), même tirage pondéré par rareté qu'un booster normal, avec repli sur la rareté la
-- plus proche si le thème n'a aucune carte de la rareté exacte tirée (themedPick côté client).
--
-- Pas de tombola pour l'instant (prochain chantier) : c'est elle qui doit normalement distribuer
-- des tickets de boosters thématiques (state.rf.themed côté prototype). En attendant, aucune
-- fonction cliente ne crée de ticket — un administrateur peut en insérer un manuellement pour
-- tester :
--   insert into public.themed_booster_tickets (profile_id, theme_id, count)
--   values ('<uuid du compte>', 'nintendo', 1)
--   on conflict (profile_id, theme_id) do update set count = themed_booster_tickets.count + 1;

-- Table de correspondance plateforme -> famille (nintendo/sony/sega/microsoft/pc/arcade/atari/snk/...).
-- card_catalogue ne stocke pas cette famille directement (seulement platform_name et sa couleur) ;
-- plutôt que de rouvrir et réimporter cette table déjà peuplée, la correspondance vit à part ici.
create table if not exists public.platform_families (
  platform_name text primary key,
  family text not null
);

alter table public.platform_families enable row level security;
drop policy if exists "platform_families_select_all" on public.platform_families;
create policy "platform_families_select_all" on public.platform_families for select using (true);

insert into public.platform_families (platform_name, family) values
  ('Switch 2', 'nintendo'),
  ('Switch', 'nintendo'),
  ('PlayStation 5', 'sony'),
  ('PS VR2', 'sony'),
  ('PS VR', 'sony'),
  ('Xbox Series X/S', 'microsoft'),
  ('Xbox One', 'microsoft'),
  ('PlayStation 4', 'sony'),
  ('Wii U', 'nintendo'),
  ('Wii', 'nintendo'),
  ('PlayStation 3', 'sony'),
  ('Xbox 360', 'microsoft'),
  ('PS Vita', 'sony'),
  ('Nintendo 3DS', 'nintendo'),
  ('Nintendo DS', 'nintendo'),
  ('GameCube', 'nintendo'),
  ('Nintendo 64', 'nintendo'),
  ('PlayStation 2', 'sony'),
  ('PlayStation', 'sony'),
  ('Dreamcast', 'sega'),
  ('Saturn', 'sega'),
  ('Mega Drive', 'sega'),
  ('Game Gear', 'sega'),
  ('Master System', 'sega'),
  ('Sega CD / 32X', 'sega'),
  ('Game Boy Advance', 'nintendo'),
  ('Game Boy Color', 'nintendo'),
  ('Game Boy', 'nintendo'),
  ('Super Nintendo', 'nintendo'),
  ('NES', 'nintendo'),
  ('Neo Geo', 'snk'),
  ('Arcade', 'arcade'),
  ('Atari 2600', 'atari'),
  ('Atari (autre)', 'atari'),
  ('PSP', 'sony'),
  ('3DO', 'arcade'),
  ('Réalité virtuelle', 'vr'),
  ('Mobile', 'mobile'),
  ('Navigateur', 'web'),
  ('Cloud', 'cloud'),
  ('Xbox', 'microsoft'),
  ('PC', 'pc')
on conflict (platform_name) do update set family = excluded.family;

-- Tickets de boosters thématiques en stock par joueur et par thème.
create table if not exists public.themed_booster_tickets (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  theme_id text not null,
  count integer not null default 0,
  primary key (profile_id, theme_id)
);

alter table public.themed_booster_tickets enable row level security;
drop policy if exists "themed_tickets_select_own" on public.themed_booster_tickets;
create policy "themed_tickets_select_own" on public.themed_booster_tickets for select using (auth.uid() = profile_id);
-- Volontairement aucune policy insert/update/delete pour le rôle authentifié : un ticket ne se
-- crée que par une fonction serveur (la tombola, à venir) ou une insertion manuelle par vous.

create or replace function public.open_themed_booster(p_theme_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_ticket_count integer;
  v_family text;
  v_year_min int;
  v_year_max int;
  v_weights numeric[];
  v_results jsonb := '[]'::jsonb;
  v_card_id text;
  v_rarity int;
  v_target_rarity int;
  v_shiny boolean;
  s int;
  d int;
  v_found boolean;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select count into v_ticket_count from public.themed_booster_tickets
    where profile_id = v_profile and theme_id = p_theme_id for update;
  if v_ticket_count is null or v_ticket_count < 1 then
    raise exception 'Aucun ticket pour ce thème.';
  end if;

  v_family := case p_theme_id
    when 'nintendo' then 'nintendo'
    when 'sony' then 'sony'
    when 'sega' then 'sega'
    when 'xbox' then 'microsoft'
    when 'pc' then 'pc'
    else null
  end;
  if p_theme_id = 'retro' then
    -- traité à part plus bas (famille dans une liste, pas une seule valeur)
    null;
  elsif p_theme_id not in ('y80','y90','y00','y10') and v_family is null then
    raise exception 'Thème inconnu : %.', p_theme_id;
  end if;

  v_year_min := case p_theme_id when 'y90' then 1990 when 'y00' then 2000 when 'y10' then 2010 else null end;
  v_year_max := case p_theme_id when 'y80' then 1990 when 'y90' then 2000 when 'y00' then 2010 else null end;

  update public.themed_booster_tickets set count = count - 1
    where profile_id = v_profile and theme_id = p_theme_id;

  for s in 0..4 loop
    if s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7]; -- W_LAST
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3]; -- W_NORMAL
    end if;
    v_target_rarity := public.pick_weighted_rarity(v_weights);

    -- Repli sur la rareté la plus proche si le thème n'a aucune carte de la rareté exacte
    -- (themedPick côté client) : d=0 essaie la rareté tirée, d=1 essaie +1 puis -1, etc.
    v_found := false;
    v_card_id := null;
    for d in 0..5 loop
      foreach v_rarity in array array[v_target_rarity + d, v_target_rarity - d]
      loop
        if v_found or v_rarity < 0 or v_rarity > 5 then continue; end if;

        select cc.card_id into v_card_id
          from public.card_catalogue cc
          left join public.platform_families pf on pf.platform_name = cc.platform_name
          where cc.rarity = v_rarity
            and (
              (p_theme_id = 'retro' and pf.family in ('arcade','atari','snk'))
              or (v_family is not null and pf.family = v_family)
              or (v_year_min is not null and v_year_max is not null and cc.year >= v_year_min and cc.year < v_year_max)
              or (p_theme_id = 'y80' and cc.year < v_year_max)
              or (p_theme_id = 'y10' and cc.year >= v_year_min)
            )
          order by random()
          limit 1;

        if v_card_id is not null then
          v_found := true;
          exit; -- ne touche plus v_rarity : il porte la rareté RÉELLE de la carte trouvée
        end if;
      end loop;
      exit when v_found;
    end loop;

    if not v_found then
      raise exception 'Catalogue insuffisant pour le thème %.', p_theme_id;
    end if;

    v_shiny := random() < (1.0 / 20); -- SHINY_RATE
    if v_shiny then
      update public.player_state set shiny_drawn_total = shiny_drawn_total + 1 where profile_id = v_profile;
    end if;
    if v_rarity = 2 then update public.player_state set pulls_rare = pulls_rare + 1 where profile_id = v_profile;
    elsif v_rarity = 3 then update public.player_state set pulls_epic = pulls_epic + 1 where profile_id = v_profile;
    elsif v_rarity = 4 then update public.player_state set pulls_legendary = pulls_legendary + 1 where profile_id = v_profile;
    elsif v_rarity = 5 then update public.player_state set pulls_mythic = pulls_mythic + 1 where profile_id = v_profile;
    end if;

    insert into public.collection (profile_id, card_id, shiny, count)
      values (v_profile, v_card_id, v_shiny, 1)
      on conflict (profile_id, card_id, shiny)
      do update set count = public.collection.count + 1;

    v_results := v_results || jsonb_build_object('card_id', v_card_id, 'rarity', v_rarity, 'shiny', v_shiny);
  end loop;

  update public.player_state set updated_at = now() where profile_id = v_profile;

  return jsonb_build_object('theme_id', p_theme_id, 'cards', v_results);
end;
$$;

revoke execute on function public.open_themed_booster(text) from public, anon;
grant execute on function public.open_themed_booster(text) to authenticated;

-- Lecture des tickets possédés, pour l'affichage côté client.
create or replace function public.get_themed_tickets()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(theme_id, count), '{}'::jsonb)
  from public.themed_booster_tickets
  where profile_id = auth.uid() and count > 0;
$$;

revoke execute on function public.get_themed_tickets() from public, anon;
grant execute on function public.get_themed_tickets() to authenticated;
