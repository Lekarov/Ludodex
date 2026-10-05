-- Ludodex Online — 026 : tombola
-- Repris de site/js/engine/raffle.js : un tirage toutes les 30 minutes, mise libre et cumulable,
-- chances proportionnelles à la mise, lot = un ticket de booster thématique. Une mise perdante
-- est intégralement remboursée ; une mise gagnante est "dépensée" contre le ticket.
--
-- DEUX ÉCARTS ASSUMÉS avec le prototype (voir raffle.js), tous deux documentés en commentaire à
-- l'endroit concerné :
-- 1. Le thème et le "pot des autres joueurs" par tour sont dérivés d'un hash déterministe
--    (hashtext), pas de l'algorithme mulberry32 exact du client — même principe (même tour =
--    même résultat pour tout le monde), mais pas bit-à-bit identique. Sans conséquence : le
--    prototype (site/) et Ludodex Online sont deux systèmes déjà complètement séparés.
-- 2. Le "pot des autres joueurs" simule une compétition de base (comme les bots du marché) pour
--    qu'un seul vrai joueur n'ait pas 100 % de chances de gagner à chaque tour faute d'adversaire.

create table if not exists public.raffle_entries (
  round bigint not null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null,
  primary key (round, profile_id)
);

alter table public.raffle_entries enable row level security;
drop policy if exists "raffle_entries_select_own" on public.raffle_entries;
create policy "raffle_entries_select_own" on public.raffle_entries for select using (auth.uid() = profile_id);
-- Volontairement aucune policy insert/update/delete : uniquement via stake_raffle()/résolution.

create table if not exists public.raffle_log (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  round bigint not null,
  theme_id text not null,
  mine integer not null,
  total integer not null,
  won boolean not null,
  resolved_at timestamptz not null default now()
);

alter table public.raffle_log enable row level security;
drop policy if exists "raffle_log_select_own" on public.raffle_log;
create policy "raffle_log_select_own" on public.raffle_log for select using (auth.uid() = profile_id);

-- Constantes partagées par les fonctions ci-dessous (pas de table de config pour si peu de valeurs) :
--   RAFFLE_MS = 30 * 60 * 1000 ; THEMES dans le même ordre que côté client (booster.js).
create or replace function public.raffle_round_of(p_time_ms bigint)
returns bigint
language sql
immutable
as $$
  select p_time_ms / (30 * 60 * 1000);
$$;

create or replace function public.raffle_theme_of(p_round bigint)
returns text
language sql
immutable
as $$
  select (array['nintendo','sony','sega','xbox','pc','retro','y80','y90','y00','y10'])[
    (mod(abs(hashtext('ludodex-raffle-theme:' || p_round)), 10)) + 1
  ];
$$;

create or replace function public.raffle_bot_pool(p_round bigint, p_now_ms bigint)
returns integer
language sql
immutable
as $$
  select floor(
    (150 + mod(abs(hashtext('ludodex-raffle-bots:' || p_round)), 451))
    * (0.15 + 0.85 * least(1.0, greatest(0.0,
        (p_now_ms - p_round * 30 * 60 * 1000)::numeric / (30 * 60 * 1000)
      )))
  )::integer;
$$;

create or replace function public.get_raffle_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  v_round bigint := public.raffle_round_of(v_now_ms);
  v_theme text := public.raffle_theme_of(v_round);
  v_bot_pool integer := public.raffle_bot_pool(v_round, v_now_ms);
  v_mine integer;
  v_last record;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select amount into v_mine from public.raffle_entries where round = v_round and profile_id = v_profile;
  v_mine := coalesce(v_mine, 0);

  select * into v_last from public.raffle_log where profile_id = v_profile order by resolved_at desc limit 1;

  return jsonb_build_object(
    'round', v_round,
    'theme_id', v_theme,
    'ends_in_ms', (v_round + 1) * 30 * 60 * 1000 - v_now_ms,
    'mine', v_mine,
    'total', v_mine + v_bot_pool,
    'last', case when v_last is null then null else jsonb_build_object(
      'theme_id', v_last.theme_id, 'mine', v_last.mine, 'total', v_last.total, 'won', v_last.won
    ) end
  );
end;
$$;

create or replace function public.stake_raffle(p_amount integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_coins integer;
  v_round bigint := public.raffle_round_of((extract(epoch from now()) * 1000)::bigint);
  v_mine integer;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_amount is null or p_amount < 1 then
    raise exception 'Mise invalide.';
  end if;

  select coins into v_coins from public.player_state where profile_id = v_profile for update;
  if v_coins is null or v_coins < p_amount then
    raise exception 'Solde insuffisant.';
  end if;

  update public.player_state set coins = coins - p_amount, updated_at = now() where profile_id = v_profile;

  insert into public.raffle_entries (round, profile_id, amount)
    values (v_round, v_profile, p_amount)
    on conflict (round, profile_id) do update set amount = raffle_entries.amount + p_amount
    returning amount into v_mine;

  return jsonb_build_object('round', v_round, 'mine', v_mine);
end;
$$;

-- Callable par n'importe quel joueur authentifié (comme resolve_auction) : ne fait que constater
-- un résultat déjà déterminé par les mises existantes et le hash déterministe du tour.
create or replace function public.resolve_expired_raffles()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_round bigint := public.raffle_round_of((extract(epoch from now()) * 1000)::bigint);
  v_round bigint;
  v_theme text;
  v_bot_pool integer;
  v_total_real integer;
  v_total_pool numeric;
  v_threshold numeric;
  v_cursor numeric;
  v_winner uuid;
  rec record;
begin
  for v_round in
    select distinct round from public.raffle_entries where round < v_current_round
  loop
    v_theme := public.raffle_theme_of(v_round);
    v_bot_pool := public.raffle_bot_pool(v_round, (v_round + 1) * 30 * 60 * 1000);
    select coalesce(sum(amount), 0) into v_total_real from public.raffle_entries where round = v_round;
    v_total_pool := v_total_real + v_bot_pool;

    v_winner := null;
    if v_total_pool > 0 then
      v_threshold := random() * v_total_pool;
      v_cursor := 0;
      for rec in select * from public.raffle_entries where round = v_round order by profile_id loop
        v_cursor := v_cursor + rec.amount;
        if v_threshold < v_cursor then
          v_winner := rec.profile_id;
          exit;
        end if;
      end loop;
      -- Si le seuil tombe au-delà de la somme des vraies mises, il tombe dans le pot des "autres
      -- joueurs" : personne ne gagne ce tour (v_winner reste null).
    end if;

    for rec in select * from public.raffle_entries where round = v_round loop
      if rec.profile_id = v_winner then
        insert into public.themed_booster_tickets (profile_id, theme_id, count)
          values (rec.profile_id, v_theme, 1)
          on conflict (profile_id, theme_id) do update set count = themed_booster_tickets.count + 1;
        insert into public.raffle_log (profile_id, round, theme_id, mine, total, won)
          values (rec.profile_id, v_round, v_theme, rec.amount, v_total_pool::integer, true);
      else
        update public.player_state set coins = coins + rec.amount, updated_at = now()
          where profile_id = rec.profile_id;
        insert into public.raffle_log (profile_id, round, theme_id, mine, total, won)
          values (rec.profile_id, v_round, v_theme, rec.amount, v_total_pool::integer, false);
      end if;
    end loop;

    delete from public.raffle_entries where round = v_round;
  end loop;
end;
$$;

revoke execute on function public.get_raffle_state() from public, anon;
revoke execute on function public.stake_raffle(integer) from public, anon;
revoke execute on function public.resolve_expired_raffles() from public, anon;
grant execute on function public.get_raffle_state() to authenticated;
grant execute on function public.stake_raffle(integer) to authenticated;
grant execute on function public.resolve_expired_raffles() to authenticated;
