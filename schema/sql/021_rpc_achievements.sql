-- Ludodex Online — 021 : succès (25 succès du prototype, ~1720 pièces au total)
-- Simplification assumée par rapport au prototype : là où site/js/engine/achievements.js sépare
-- le déblocage (silencieux, dès la condition remplie) de la récupération (bouton manuel), une
-- seule fonction fait les deux d'un coup ici : plus simple à sécuriser pour un v1, quitte à
-- séparer plus tard si l'UX doit vraiment distinguer "débloqué" de "récupéré".
--
-- Deux succès du prototype ne peuvent pas encore se déclencher : "raf" (gagner une tombola) et
-- "win" (remporter une enchère) — ni la tombola ni les enchères n'existent encore côté serveur.
-- Ils sont listés ici avec une condition toujours fausse (objectif inatteignable) plutôt
-- qu'omis, pour que la liste des 25 succès reste complète côté affichage (voir jeu.js) : le
-- jour où tombola/enchères existent, il suffira de brancher leur compteur ici.

create or replace function public.sync_and_claim_achievements()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_owned_distinct integer;
  v_catalogue_total integer;
  v_platforms_completed integer;
  v_sold_count integer;
  v_bought_count integer;
  v_earned integer;
  v_total_reward integer := 0;
  v_granted jsonb := '[]'::jsonb;
  rec record;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  select count(distinct card_id) into v_owned_distinct from public.collection where profile_id = v_profile;
  select count(*) into v_catalogue_total from public.card_catalogue;
  select count(*) into v_sold_count from public.market_listings where seller_profile_id = v_profile and status = 'sold';
  select count(*) into v_bought_count from public.market_listings where buyer_profile_id = v_profile and status = 'sold';
  select coalesce(sum(price), 0) into v_earned from public.market_listings where seller_profile_id = v_profile and status = 'sold';

  select count(*) into v_platforms_completed from (
    select cc.platform_name
    from public.card_catalogue cc
    group by cc.platform_name
    having count(*) = (
      select count(*)
      from public.collection c
      join public.card_catalogue cc2 on cc2.card_id = c.card_id
      where c.profile_id = v_profile and cc2.platform_name = cc.platform_name
    )
  ) done_platforms;

  -- Déblocage : toute définition dont la valeur atteint l'objectif et pas encore enregistrée.
  with defs(achievement_id, val, goal) as (
    values
      ('b1',   v_state.boosters_opened_total, 1),
      ('b10',  v_state.boosters_opened_total, 10),
      ('b50',  v_state.boosters_opened_total, 50),
      ('b100', v_state.boosters_opened_total, 100),
      ('b250', v_state.boosters_opened_total, 250),
      ('gold', v_state.golds_opened_total, 1),
      ('c10',  v_owned_distinct, 10),
      ('c25',  v_owned_distinct, 25),
      ('c50',  v_owned_distinct, 50),
      ('c100', v_owned_distinct, 100),
      ('call', v_owned_distinct, v_catalogue_total),
      ('set1', v_platforms_completed, 1),
      ('set5', v_platforms_completed, 5),
      ('r2',   v_state.pulls_rare, 1),
      ('r3',   v_state.pulls_epic, 1),
      ('r4',   v_state.pulls_legendary, 1),
      ('r5',   v_state.pulls_mythic, 1),
      ('sh1',  v_state.shiny_drawn_total, 1),
      ('sh5',  v_state.shiny_drawn_total, 5),
      ('m1',   v_bought_count, 1),
      ('m2',   v_sold_count, 1),
      ('m10',  v_sold_count, 10),
      ('earn', v_earned, 1000),
      ('raf',  0, 1), -- tombola pas encore implémentée : jamais atteint
      ('win',  0, 1)  -- enchères pas encore implémentées : jamais atteint
  )
  insert into public.achievements_unlocked (profile_id, achievement_id)
  select v_profile, achievement_id from defs where val >= goal
  on conflict (profile_id, achievement_id) do nothing;

  -- Récupération : verse la récompense de chaque succès débloqué pas encore payé.
  for rec in
    with rewards(achievement_id, reward) as (
      values
        ('b1', 10), ('b10', 25), ('b50', 60), ('b100', 100), ('b250', 150),
        ('gold', 20), ('c10', 20), ('c25', 40), ('c50', 80), ('c100', 150), ('call', 300),
        ('set1', 60), ('set5', 150),
        ('r2', 15), ('r3', 30), ('r4', 60), ('r5', 120),
        ('sh1', 40), ('sh5', 100),
        ('m1', 10), ('m2', 15), ('m10', 50), ('earn', 75),
        ('raf', 20), ('win', 25)
    )
    update public.achievements_unlocked au
      set reward_granted = true, reward_granted_at = now()
      from rewards r
      where au.profile_id = v_profile
        and au.achievement_id = r.achievement_id
        and au.reward_granted = false
      returning au.achievement_id, r.reward
  loop
    v_total_reward := v_total_reward + rec.reward;
    v_granted := v_granted || jsonb_build_object('achievement_id', rec.achievement_id, 'reward', rec.reward);
  end loop;

  if v_total_reward > 0 then
    update public.player_state set coins = coins + v_total_reward, updated_at = now() where profile_id = v_profile;
  end if;

  return jsonb_build_object('granted', v_granted, 'total_reward', v_total_reward);
end;
$$;

revoke execute on function public.sync_and_claim_achievements() from public, anon;
grant execute on function public.sync_and_claim_achievements() to authenticated;

-- Lecture seule des mêmes métriques, pour que le client affiche une barre de progression sans
-- dupliquer la logique SQL (jointure plateformes notamment) côté jeu.js.
create or replace function public.get_achievement_progress()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_owned_distinct integer;
  v_catalogue_total integer;
  v_platforms_completed integer;
  v_sold_count integer;
  v_bought_count integer;
  v_earned integer;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile;
  select count(distinct card_id) into v_owned_distinct from public.collection where profile_id = v_profile;
  select count(*) into v_catalogue_total from public.card_catalogue;
  select count(*) into v_sold_count from public.market_listings where seller_profile_id = v_profile and status = 'sold';
  select count(*) into v_bought_count from public.market_listings where buyer_profile_id = v_profile and status = 'sold';
  select coalesce(sum(price), 0) into v_earned from public.market_listings where seller_profile_id = v_profile and status = 'sold';

  select count(*) into v_platforms_completed from (
    select cc.platform_name
    from public.card_catalogue cc
    group by cc.platform_name
    having count(*) = (
      select count(*)
      from public.collection c
      join public.card_catalogue cc2 on cc2.card_id = c.card_id
      where c.profile_id = v_profile and cc2.platform_name = cc.platform_name
    )
  ) done_platforms;

  return jsonb_build_object(
    'boosters_opened_total', v_state.boosters_opened_total,
    'golds_opened_total', v_state.golds_opened_total,
    'shiny_drawn_total', v_state.shiny_drawn_total,
    'pulls_rare', v_state.pulls_rare,
    'pulls_epic', v_state.pulls_epic,
    'pulls_legendary', v_state.pulls_legendary,
    'pulls_mythic', v_state.pulls_mythic,
    'owned_distinct', v_owned_distinct,
    'catalogue_total', v_catalogue_total,
    'platforms_completed', v_platforms_completed,
    'sold_count', v_sold_count,
    'bought_count', v_bought_count,
    'earned', v_earned
  );
end;
$$;

revoke execute on function public.get_achievement_progress() from public, anon;
grant execute on function public.get_achievement_progress() to authenticated;
