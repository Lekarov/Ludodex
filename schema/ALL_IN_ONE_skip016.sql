-- ============================================================
-- FICHIER: 001_extensions_and_enums.sql
-- ============================================================
-- Ludodex Online — 001 : extensions et types énumérés
-- À exécuter en premier. Ne modifie aucune donnée existante (rien n'existe encore).

create extension if not exists pgcrypto;

do $$ begin
  create type profile_role as enum ('player', 'vip', 'moderator', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type market_party_type as enum ('bot', 'player');
exception when duplicate_object then null; end $$;

do $$ begin
  create type listing_type as enum ('sale', 'auction');
exception when duplicate_object then null; end $$;

do $$ begin
  create type listing_status as enum ('active', 'sold', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type report_status as enum ('pending', 'reviewed');
exception when duplicate_object then null; end $$;

-- ============================================================
-- FICHIER: 002_profiles.sql
-- ============================================================
-- Ludodex Online — 002 : profils
-- Un profil par compte, créé automatiquement à l'inscription (jamais par le client directement).

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  role profile_role not null default 'player',
  collection_public boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Lecture publique : nécessaire pour afficher un vendeur sur le marché ou un pseudo en chat.
drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all"
  on public.profiles for select
  using (true);

-- Un joueur ne modifie que son propre réglage de confidentialité de collection, jamais son rôle.
drop policy if exists "profiles_update_own_non_role_fields" on public.profiles;
create policy "profiles_update_own_non_role_fields"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Empêche un joueur de changer son propre rôle même via la policy d'update ci-dessus :
-- seul un appel effectué avec la clé de service (donc hors RLS) peut changer `role`.
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
as $$
begin
  if new.role is distinct from old.role and auth.uid() = old.id then
    raise exception 'Le rôle ne peut pas être modifié par le joueur lui-même.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_role_self_escalation on public.profiles;
create trigger trg_prevent_role_self_escalation
  before update on public.profiles
  for each row execute function public.prevent_role_self_escalation();

-- Création automatique du profil à l'inscription (email/mdp, Google ou Discord).
-- Le username par défaut est temporaire (à partir de l'email) ; le joueur pourra le changer
-- ensuite via son propre update (soumis à la contrainte unique).
-- LIMITE CONNUE : si deux comptes ont le même préfixe d'email, l'insert peut échouer sur la
-- contrainte unique de `username` et bloquer l'inscription. À renforcer avant la mise en ligne
-- réelle (par ex. suffixe aléatoire systématique) — noté ici, pas encore corrigé.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(split_part(new.email, '@', 1), 'joueur_' || substr(new.id::text, 1, 8)));
  return new;
end;
$$;

drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- FICHIER: 003_player_state.sql
-- ============================================================
-- Ludodex Online — 003 : état de jeu (pièces, boosters)
-- Aucune écriture cliente n'est autorisée sur cette table : seules des fonctions serveur
-- (à écrire dans une étape suivante) pourront la modifier, en s'exécutant avec les droits du
-- propriétaire de la table (qui contourne naturellement la RLS ci-dessous).

create table if not exists public.player_state (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  coins integer not null default 0,
  boosters_available integer not null default 0,
  last_regen_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.player_state enable row level security;

-- Lecture strictement privée : personne d'autre ne voit le solde de pièces d'un joueur.
drop policy if exists "player_state_select_own" on public.player_state;
create policy "player_state_select_own"
  on public.player_state for select
  using (auth.uid() = profile_id);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- toute mutation devra passer par une fonction serveur dédiée (étape suivante).

-- Création automatique d'un état de jeu par défaut en même temps que le profil.
create or replace function public.handle_new_player_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.player_state (profile_id) values (new.id);
  return new;
end;
$$;

drop trigger if exists trg_handle_new_player_state on public.profiles;
create trigger trg_handle_new_player_state
  after insert on public.profiles
  for each row execute function public.handle_new_player_state();

-- ============================================================
-- FICHIER: 004_collection.sql
-- ============================================================
-- Ludodex Online — 004 : collection de cartes par joueur
-- card_id référence le catalogue statique (fichiers JSON sur le NAS), pas une table SQL :
-- aucune clé étrangère possible ici, la cohérence est assurée côté application.

create table if not exists public.collection (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null,
  shiny boolean not null default false,
  count integer not null default 1,
  obtained_at timestamptz not null default now(),
  primary key (profile_id, card_id, shiny)
);

alter table public.collection enable row level security;

-- Le propriétaire voit toujours sa collection ; les autres joueurs seulement si elle est publique.
drop policy if exists "collection_select_own_or_public" on public.collection;
create policy "collection_select_own_or_public"
  on public.collection for select
  using (
    auth.uid() = profile_id
    or exists (
      select 1 from public.profiles p
      where p.id = collection.profile_id and p.collection_public = true
    )
  );

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- une carte n'est ajoutée que via une fonction serveur (ouverture de booster, achat au marché).

-- ============================================================
-- FICHIER: 005_achievements.sql
-- ============================================================
-- Ludodex Online — 005 : succès débloqués
-- Trace permanente du versement de la récompense, pour ne jamais la donner deux fois même si
-- le succès est retravaillé plus tard.

create table if not exists public.achievements_unlocked (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  achievement_id text not null,
  unlocked_at timestamptz not null default now(),
  reward_granted boolean not null default false,
  reward_granted_at timestamptz,
  primary key (profile_id, achievement_id)
);

alter table public.achievements_unlocked enable row level security;

drop policy if exists "achievements_select_own" on public.achievements_unlocked;
create policy "achievements_select_own"
  on public.achievements_unlocked for select
  using (auth.uid() = profile_id);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- un succès n'est débloqué et récompensé que via une fonction serveur.

-- ============================================================
-- FICHIER: 006_market.sql
-- ============================================================
-- Ludodex Online — 006 : marché (annonces et enchères)
-- Vendeur/acheteur générique (bot ou joueur) dès maintenant, même si seuls les bots
-- vendent/achètent au début (décision prise avec l'utilisateur).

create table if not exists public.market_listings (
  id uuid primary key default gen_random_uuid(),
  seller_type market_party_type not null,
  seller_profile_id uuid references public.profiles(id) on delete cascade,
  bot_name text,
  card_id text not null,
  shiny boolean not null default false,
  listing_type listing_type not null,
  price integer,
  status listing_status not null default 'active',
  created_at timestamptz not null default now(),
  constraint seller_matches_type check (
    (seller_type = 'player' and seller_profile_id is not null and bot_name is null)
    or (seller_type = 'bot' and seller_profile_id is null and bot_name is not null)
  )
);

alter table public.market_listings enable row level security;

-- Le marché est public : tout le monde voit toutes les annonces.
drop policy if exists "market_listings_select_all" on public.market_listings;
create policy "market_listings_select_all"
  on public.market_listings for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- une annonce n'est créée/résolue que via une fonction serveur (vérifie la carte possédée,
-- débite/crédite les pièces de façon atomique).

create table if not exists public.market_bids (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.market_listings(id) on delete cascade,
  bidder_type market_party_type not null,
  bidder_profile_id uuid references public.profiles(id) on delete cascade,
  amount integer not null,
  created_at timestamptz not null default now(),
  constraint bidder_matches_type check (
    (bidder_type = 'player' and bidder_profile_id is not null)
    or (bidder_type = 'bot' and bidder_profile_id is null)
  )
);

alter table public.market_bids enable row level security;

drop policy if exists "market_bids_select_all" on public.market_bids;
create policy "market_bids_select_all"
  on public.market_bids for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié :
-- une enchère n'est acceptée que via une fonction serveur qui vérifie les fonds du joueur.

-- ============================================================
-- FICHIER: 007_messages_and_moderation.sql
-- ============================================================
-- Ludodex Online — 007 : messages privés, signalements, blocages
-- Chat privé disponible dès le lancement, avec signalement/blocage dès le départ (décision
-- prise avec l'utilisateur, plus sensible qu'un salon public).

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

alter table public.blocks enable row level security;

drop policy if exists "blocks_select_own" on public.blocks;
create policy "blocks_select_own"
  on public.blocks for select
  using (auth.uid() = blocker_id);

drop policy if exists "blocks_insert_own" on public.blocks;
create policy "blocks_insert_own"
  on public.blocks for insert
  with check (auth.uid() = blocker_id);

drop policy if exists "blocks_delete_own" on public.blocks;
create policy "blocks_delete_own"
  on public.blocks for delete
  using (auth.uid() = blocker_id);

create table if not exists public.private_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

alter table public.private_messages enable row level security;

-- Lu uniquement par l'expéditeur et le destinataire (le modérateur passe par message_reports,
-- pas par un accès direct à toute la table).
drop policy if exists "private_messages_select_participants" on public.private_messages;
create policy "private_messages_select_participants"
  on public.private_messages for select
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- Envoi autorisé sauf si le destinataire a bloqué l'expéditeur.
drop policy if exists "private_messages_insert_if_not_blocked" on public.private_messages;
create policy "private_messages_insert_if_not_blocked"
  on public.private_messages for insert
  with check (
    auth.uid() = sender_id
    and not exists (
      select 1 from public.blocks b
      where b.blocker_id = recipient_id and b.blocked_id = sender_id
    )
  );

create table if not exists public.message_reports (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.private_messages(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null,
  status report_status not null default 'pending',
  reviewed_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.message_reports enable row level security;

drop policy if exists "message_reports_insert_own" on public.message_reports;
create policy "message_reports_insert_own"
  on public.message_reports for insert
  with check (auth.uid() = reporter_id);

drop policy if exists "message_reports_select_own_or_moderation" on public.message_reports;
create policy "message_reports_select_own_or_moderation"
  on public.message_reports for select
  using (
    auth.uid() = reporter_id
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('moderator', 'admin')
    )
  );

drop policy if exists "message_reports_update_moderation_only" on public.message_reports;
create policy "message_reports_update_moderation_only"
  on public.message_reports for update
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('moderator', 'admin')
    )
  );

-- Nettoyage à 30 jours : nécessite l'extension pg_cron (à activer depuis le dashboard,
-- Database → Extensions) puis planifier l'appel de cette fonction une fois par jour.
-- Non activé automatiquement ici — étape volontairement laissée à vous.
create or replace function public.purge_old_message_reports()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.message_reports where created_at < now() - interval '30 days';
$$;

-- ============================================================
-- FICHIER: 008_card_catalogue.sql
-- ============================================================
-- Ludodex Online — 008 : catalogue de cartes (id stable + rareté)
-- Copie minimale du catalogue (pas de titre, image, description : ça reste sur le NAS) pour que
-- les fonctions serveur (RPC, étape suivante) puissent tirer un booster sans faire confiance au
-- client. card_id = `id` stable des sources catalogue (ex. "igdb:12345"), jamais l'index de
-- tableau utilisé côté client dans GAMES — voir passation du 26/09/2026 pour le pourquoi.
--
-- Contenu généré par schema/catalogue_import/generate_card_catalogue.js (rejoue exactement
-- computeStats + assignRarity de site/js/data/catalogue-loader.js) puis importé manuellement
-- (Table Editor → card_catalogue → Insert → Import data from CSV) depuis
-- schema/catalogue_import/card_catalogue.csv. À régénérer et réimporter si le catalogue change
-- de façon notable (la rareté est un classement par percentile sur tout le catalogue).

create table if not exists public.card_catalogue (
  card_id text primary key,
  rarity smallint not null check (rarity between 0 and 5),
  updated_at timestamptz not null default now()
);

alter table public.card_catalogue enable row level security;

-- Lecture publique : les fonctions serveur (security definer) n'en ont pas besoin, mais rien
-- n'est sensible ici (juste un id et une rareté), et ça évite de bloquer un futur usage client
-- en lecture seule (ex. filtrer le marché par rareté sans dupliquer cette info).
drop policy if exists "card_catalogue_select_all" on public.card_catalogue;
create policy "card_catalogue_select_all"
  on public.card_catalogue for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour le rôle authentifié : l'import se fait
-- par vous via le Table Editor (bypass RLS), jamais par un joueur.

-- ============================================================
-- FICHIER: 009_player_state_pity.sql
-- ============================================================
-- Ludodex Online — 009 : compteur de pity (booster doré)
-- Manquait dans 003 : nécessaire pour reproduire côté serveur "le 10e booster est doré"
-- (state.sinceGold côté site, voir site/js/engine/packs.js et GOLD_EVERY dans constants.js).

alter table public.player_state
  add column if not exists opens_since_gold integer not null default 0;

-- ============================================================
-- FICHIER: 010_rpc_open_booster.sql
-- ============================================================
-- Ludodex Online — 010 : fonction serveur open_booster()
-- Seule façon d'ajouter des cartes à une collection par ouverture de booster : le client ne
-- peut ni choisir la carte, ni la rareté, ni le stock restant. Logique copiée à l'identique de
-- site/js/engine/packs.js + site/js/config/constants.js (régénération 1/10 min, stock max 10,
-- 10e booster doré, poids de rareté par emplacement, 5 % de brillante) pour que le comportement
-- reste cohérent avec le prototype si un jour il se connecte à ce backend.
--
-- LIMITE CONNUE : le tirage d'une carte au hasard dans card_catalogue utilise
-- `order by random() limit 1`, donc un scan complet de la tranche de rareté à chaque carte
-- tirée (jusqu'à ~13000 lignes pour "Commune"). Largement suffisant pour un trafic de hobby sur
-- un compute nano ; à revoir seulement si ça devient un vrai goulot d'étranglement.

create or replace function public.pick_weighted_rarity(weights numeric[])
returns int
language plpgsql
as $$
declare
  total numeric := 0;
  x numeric;
  i int;
begin
  for i in 1..array_length(weights, 1) loop
    total := total + weights[i];
  end loop;
  x := random() * total;
  for i in 1..array_length(weights, 1) loop
    x := x - weights[i];
    if x < 0 then
      return i - 1; -- rareté 0-based (0 = Commune ... 5 = Mythique)
    end if;
  end loop;
  return array_length(weights, 1) - 1;
end;
$$;

revoke execute on function public.pick_weighted_rarity(numeric[]) from public, anon, authenticated;

create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_now timestamptz := now();
  v_regen_ms constant bigint := 10 * 60 * 1000; -- REGEN_MS
  v_max_packs constant int := 10;               -- MAX_PACKS
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

revoke execute on function public.open_booster() from public, anon;
grant execute on function public.open_booster() to authenticated;

-- ============================================================
-- FICHIER: 011_rpc_delete_account.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 012_player_state_defaults.sql
-- ============================================================
-- Ludodex Online — 012 : valeurs par défaut de player_state alignées sur le prototype
-- Deux écarts avec fresh() (site/js/persistence/save.js) corrigés avant qu'ils ne posent
-- problème sur de vrais comptes :
-- - boosters_available démarrait à 0 (003_player_state.sql), au lieu du stock plein (MAX_PACKS).
-- - coins démarrait à 0 (003_player_state.sql), au lieu de START_COINS (500).

alter table public.player_state
  alter column boosters_available set default 10,
  alter column coins set default 500;

-- Ne change pas les lignes déjà créées (ex. le compte de test) : mise à jour volontairement
-- laissée à vous si vous voulez aussi appliquer ces valeurs à un compte existant :
--   update public.player_state set boosters_available = 10, coins = 500
--     where profile_id = '<uuid du compte>';

-- ============================================================
-- FICHIER: 013_rpc_discard_card.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 014_rpc_market_sale.sql
-- ============================================================
-- Ludodex Online — 014 : marché, vente directe joueur-à-joueur (create/cancel/buy)
--
-- PÉRIMÈTRE VOLONTAIREMENT RÉDUIT : seul le type d'annonce "sale" (vente à prix fixe) est
-- implémenté ici. Les enchères ("auction") existent dans le schéma (006_market.sql,
-- market_bids) mais pas encore de RPC : une vraie enchère a besoin d'une date de fin, d'une
-- résolution différée (qui gagne quand ça se termine, avec des pièces qui restaient
-- "disponibles" jusque-là) et d'un mécanisme qui déclenche cette résolution (cron ou appel
-- explicite) — ça mérite sa propre passe de conception, pas un ajout rapide. Les bots du
-- marché (voir cadrage) ne sont pas non plus implémentés : pour l'instant le marché est
-- exclusivement joueur-à-joueur, avec zéro annonce tant que personne n'en crée.
--
-- Commission 0 % (FEE=0 dans le prototype) : l'acheteur paie exactement le prix affiché, le
-- vendeur reçoit exactement ce montant.
--
-- Modèle retenu : mettre une carte en vente la RETIRE immédiatement de la collection du
-- vendeur (déposée en "séquestre" dans l'annonce) ; annuler ou vendre la restitue au vendeur
-- ou la transfère à l'acheteur. Évite qu'une carte mise en vente soit revendue ou défaussée
-- deux fois pendant qu'elle est listée.

create or replace function public.create_sale_listing(p_card_id text, p_shiny boolean, p_price integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_count integer;
  v_listing_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_price is null or p_price < 1 then
    raise exception 'Le prix doit être supérieur à 0.';
  end if;
  if not exists (select 1 from public.card_catalogue where card_id = p_card_id) then
    raise exception 'Carte inconnue : %.', p_card_id;
  end if;

  select count into v_count from public.collection
    where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny
    for update;
  if v_count is null or v_count < 1 then
    raise exception 'Tu ne possèdes pas cette carte.';
  end if;

  if v_count = 1 then
    delete from public.collection where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  else
    update public.collection set count = count - 1
      where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  end if;

  insert into public.market_listings (seller_type, seller_profile_id, card_id, shiny, listing_type, price, status)
    values ('player', v_profile, p_card_id, p_shiny, 'sale', p_price, 'active')
    returning id into v_listing_id;

  return v_listing_id;
end;
$$;

create or replace function public.cancel_sale_listing(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.seller_type <> 'player' or v_listing.seller_profile_id <> v_profile then
    raise exception 'Cette annonce ne t''appartient pas.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette annonce n''est plus active.';
  end if;

  update public.market_listings set status = 'cancelled' where id = p_listing_id;

  insert into public.collection (profile_id, card_id, shiny, count)
    values (v_profile, v_listing.card_id, v_listing.shiny, 1)
    on conflict (profile_id, card_id, shiny)
    do update set count = public.collection.count + 1;
end;
$$;

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

  update public.market_listings set status = 'sold' where id = p_listing_id;

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

revoke execute on function public.create_sale_listing(text, boolean, integer) from public, anon;
revoke execute on function public.cancel_sale_listing(uuid) from public, anon;
revoke execute on function public.buy_listing(uuid) from public, anon;
grant execute on function public.create_sale_listing(text, boolean, integer) to authenticated;
grant execute on function public.cancel_sale_listing(uuid) to authenticated;
grant execute on function public.buy_listing(uuid) to authenticated;

-- ============================================================
-- FICHIER: 015_card_catalogue_display_fields.sql
-- ============================================================
-- Ludodex Online — 015 : card_catalogue devient aussi la source d'affichage
-- Jusqu'ici jeu.js téléchargeait tout le catalogue (~32 000 jeux, dont un fichier de ~16 Mo)
-- côté navigateur juste pour retrouver le titre/l'image des quelques cartes possédées par le
-- joueur — beaucoup trop lent pour un usage réel. On enrichit card_catalogue avec les champs
-- d'affichage nécessaires (titre, plateforme, année, image, ATK/DEF, couleur de rareté) pour
-- que le client n'ait plus qu'à demander à Supabase les cartes qu'il affiche réellement.
--
-- Table entièrement recréée (DROP + CREATE) plutôt qu'ALTER, plus simple pour changer autant de
-- colonnes d'un coup sur une table qui ne contient que des données dérivées, régénérables.
--
-- IMPORTANT — ORDRE : ce fichier recrée la table VIDE. Réimportez le CSV régénéré
-- (schema/catalogue_import/card_catalogue.csv, Table Editor → card_catalogue → Insert → Import
-- data from CSV) AVANT d'exécuter 016 (qui ajoute les clés étrangères depuis collection et
-- market_listings) — sinon 016 échoue si un compte a déjà des cartes en collection.

drop table if exists public.card_catalogue cascade;

create table public.card_catalogue (
  card_id text primary key,
  rarity smallint not null check (rarity between 0 and 5),
  rarity_name text not null,
  rarity_color text not null,
  family_color text not null,
  title text not null,
  platform_name text not null,
  year integer,
  developer text,
  image_url text,
  atk integer not null,
  def integer not null,
  updated_at timestamptz not null default now()
);

alter table public.card_catalogue enable row level security;

create policy "card_catalogue_select_all"
  on public.card_catalogue for select
  using (true);

-- ============================================================
-- FICHIER: 017_player_state_stat_counters.sql
-- ============================================================
-- Ludodex Online — 017 : compteurs cumulés nécessaires aux succès
-- Le prototype dérive ses succès de state.opened/state.golds/state.shinyDrawn/state.byR (compteurs
-- cumulés, jamais décrémentés même si une carte est ensuite défaussée/vendue). Rien de tel
-- n'existait côté serveur : collection ne reflète que l'état ACTUEL, pas l'historique.

alter table public.player_state
  add column if not exists boosters_opened_total integer not null default 0,
  add column if not exists golds_opened_total integer not null default 0,
  add column if not exists shiny_drawn_total integer not null default 0,
  add column if not exists pulls_rare integer not null default 0,       -- rareté 2 (Rare) ou mieux tirée au moins une fois compte ici à chaque tirage
  add column if not exists pulls_epic integer not null default 0,       -- rareté 3 (Épique)
  add column if not exists pulls_legendary integer not null default 0, -- rareté 4 (Légendaire)
  add column if not exists pulls_mythic integer not null default 0;    -- rareté 5 (Mythique)

-- ============================================================
-- FICHIER: 018_market_listings_buyer.sql
-- ============================================================
-- Ludodex Online — 018 : traçabilité de l'acheteur sur une vente
-- Nécessaire pour le succès "Premier achat" (m1) et un futur historique d'achats : jusqu'ici
-- buy_listing() ne laissait aucune trace de qui avait acheté une annonce une fois vendue.

alter table public.market_listings
  add column if not exists buyer_profile_id uuid references public.profiles(id);

-- ============================================================
-- FICHIER: 019_open_booster_track_stats.sql
-- ============================================================
-- Ludodex Online — 019 : open_booster() alimente les compteurs de succès
-- Redéfinit la fonction créée en 010 (create or replace, sûr : ne casse aucun appelant) pour
-- incrémenter boosters_opened_total / golds_opened_total / shiny_drawn_total / pulls_* à chaque
-- tirage, en plus de sa logique existante (inchangée).

create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_now timestamptz := now();
  v_regen_ms constant bigint := 10 * 60 * 1000; -- REGEN_MS
  v_max_packs constant int := 10;               -- MAX_PACKS
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
  v_state.boosters_opened_total := v_state.boosters_opened_total + 1;
  if v_gold then
    v_state.golds_opened_total := v_state.golds_opened_total + 1;
  end if;

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
    if v_shiny then
      v_state.shiny_drawn_total := v_state.shiny_drawn_total + 1;
    end if;
    if v_rarity = 2 then v_state.pulls_rare := v_state.pulls_rare + 1;
    elsif v_rarity = 3 then v_state.pulls_epic := v_state.pulls_epic + 1;
    elsif v_rarity = 4 then v_state.pulls_legendary := v_state.pulls_legendary + 1;
    elsif v_rarity = 5 then v_state.pulls_mythic := v_state.pulls_mythic + 1;
    end if;

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
        boosters_opened_total = v_state.boosters_opened_total,
        golds_opened_total = v_state.golds_opened_total,
        shiny_drawn_total = v_state.shiny_drawn_total,
        pulls_rare = v_state.pulls_rare,
        pulls_epic = v_state.pulls_epic,
        pulls_legendary = v_state.pulls_legendary,
        pulls_mythic = v_state.pulls_mythic,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;

-- ============================================================
-- FICHIER: 020_buy_listing_track_buyer.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 021_rpc_achievements.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 022_market_listings_ends_at.sql
-- ============================================================
-- Ludodex Online — 022 : date de fin pour les enchères
-- Nécessaire pour savoir quand une enchère se termine et doit être résolue (voir 023).

alter table public.market_listings
  add column if not exists ends_at timestamptz;

-- ============================================================
-- FICHIER: 023_rpc_auctions.sql
-- ============================================================
-- Ludodex Online — 023 : enchères (création, mise, résolution, annulation)
--
-- Pas de "pièces bloquées" en continu (contrairement au prototype) : une mise n'est validée que
-- contre le solde DISPONIBLE au moment où elle est posée. Au moment de la résolution, on revérifie
-- que le plus offrant a toujours assez de pièces ; sinon on descend à l'offre suivante, en
-- cascade, jusqu'à en trouver une valide (ou aucune). Documenté comme limite connue : un joueur
-- peut dépenser ses pièces ailleurs entre sa mise et la résolution, ce qui invalide sa propre
-- offre — plus simple à sécuriser qu'un vrai verrou de fonds pour ce v1.
--
-- Pas de résolution automatique programmée (pas de pg_cron ici) : resolve_auction() doit être
-- appelée explicitement une fois ends_at dépassé — le client (jeu.js) le fait pour chaque
-- enchère expirée qu'il affiche.

create or replace function public.create_auction_listing(p_card_id text, p_shiny boolean, p_start_price integer, p_duration_minutes integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_count integer;
  v_listing_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_start_price is null or p_start_price < 1 then
    raise exception 'La mise de départ doit être supérieure à 0.';
  end if;
  if p_duration_minutes is null or p_duration_minutes not in (30, 120, 1440) then
    raise exception 'Durée invalide.';
  end if;
  if not exists (select 1 from public.card_catalogue where card_id = p_card_id) then
    raise exception 'Carte inconnue : %.', p_card_id;
  end if;

  select count into v_count from public.collection
    where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny
    for update;
  if v_count is null or v_count < 1 then
    raise exception 'Tu ne possèdes pas cette carte.';
  end if;

  if v_count = 1 then
    delete from public.collection where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  else
    update public.collection set count = count - 1
      where profile_id = v_profile and card_id = p_card_id and shiny = p_shiny;
  end if;

  insert into public.market_listings (seller_type, seller_profile_id, card_id, shiny, listing_type, price, status, ends_at)
    values ('player', v_profile, p_card_id, p_shiny, 'auction', p_start_price, 'active', now() + (p_duration_minutes || ' minutes')::interval)
    returning id into v_listing_id;

  return v_listing_id;
end;
$$;

create or replace function public.place_bid(p_listing_id uuid, p_amount integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
  v_top_bid integer;
  v_min_next integer;
  v_bidder_coins integer;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.listing_type <> 'auction' then
    raise exception 'Cette annonce n''est pas une enchère.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette enchère n''est plus active.';
  end if;
  if v_listing.ends_at <= now() then
    raise exception 'Cette enchère est terminée.';
  end if;
  if v_listing.seller_type = 'player' and v_listing.seller_profile_id = v_profile then
    raise exception 'Tu ne peux pas enchérir sur ta propre annonce.';
  end if;

  select max(amount) into v_top_bid from public.market_bids where listing_id = p_listing_id;
  v_min_next := coalesce(v_top_bid + greatest(1, round(v_top_bid * 0.07)), v_listing.price);
  if p_amount < v_min_next then
    raise exception 'Mise minimale : %.', v_min_next;
  end if;

  select coins into v_bidder_coins from public.player_state where profile_id = v_profile;
  if v_bidder_coins is null or v_bidder_coins < p_amount then
    raise exception 'Pas assez de pièces pour cette mise.';
  end if;

  insert into public.market_bids (listing_id, bidder_type, bidder_profile_id, amount)
    values (p_listing_id, 'player', v_profile, p_amount);
end;
$$;

create or replace function public.cancel_auction_listing(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.seller_type <> 'player' or v_listing.seller_profile_id <> v_profile then
    raise exception 'Cette annonce ne t''appartient pas.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette annonce n''est plus active.';
  end if;
  if exists (select 1 from public.market_bids where listing_id = p_listing_id) then
    raise exception 'Impossible d''annuler : des enchères ont déjà été placées.';
  end if;

  update public.market_listings set status = 'cancelled' where id = p_listing_id;

  insert into public.collection (profile_id, card_id, shiny, count)
    values (v_profile, v_listing.card_id, v_listing.shiny, 1)
    on conflict (profile_id, card_id, shiny)
    do update set count = public.collection.count + 1;
end;
$$;

-- Callable par n'importe quel joueur authentifié (pas seulement le vendeur) : ne fait que
-- constater un résultat déjà déterminé par les mises existantes, aucune valeur fournie par
-- l'appelant n'influence le résultat.
create or replace function public.resolve_auction(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.market_listings%rowtype;
  v_bid record;
  v_winner_coins integer;
  v_resolved boolean := false;
begin
  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.listing_type <> 'auction' or v_listing.status <> 'active' then
    return; -- déjà résolue ou n'est pas une enchère : rien à faire, pas une erreur
  end if;
  if v_listing.ends_at > now() then
    raise exception 'Cette enchère n''est pas encore terminée.';
  end if;

  for v_bid in
    select * from public.market_bids
    where listing_id = p_listing_id
    order by amount desc, created_at asc
  loop
    select coins into v_winner_coins from public.player_state where profile_id = v_bid.bidder_profile_id for update;
    if v_winner_coins is not null and v_winner_coins >= v_bid.amount then
      update public.market_listings set status = 'sold', buyer_profile_id = v_bid.bidder_profile_id where id = p_listing_id;
      update public.player_state set coins = coins - v_bid.amount, updated_at = now() where profile_id = v_bid.bidder_profile_id;
      if v_listing.seller_type = 'player' then
        update public.player_state set coins = coins + v_bid.amount, updated_at = now() where profile_id = v_listing.seller_profile_id;
      end if;
      insert into public.collection (profile_id, card_id, shiny, count)
        values (v_bid.bidder_profile_id, v_listing.card_id, v_listing.shiny, 1)
        on conflict (profile_id, card_id, shiny)
        do update set count = public.collection.count + 1;
      v_resolved := true;
      exit;
    end if;
  end loop;

  if not v_resolved then
    -- Aucune offre valide (ou aucune offre du tout) : la carte revient au vendeur.
    update public.market_listings set status = 'cancelled' where id = p_listing_id;
    if v_listing.seller_type = 'player' then
      insert into public.collection (profile_id, card_id, shiny, count)
        values (v_listing.seller_profile_id, v_listing.card_id, v_listing.shiny, 1)
        on conflict (profile_id, card_id, shiny)
        do update set count = public.collection.count + 1;
    end if;
  end if;
end;
$$;

revoke execute on function public.create_auction_listing(text, boolean, integer, integer) from public, anon;
revoke execute on function public.place_bid(uuid, integer) from public, anon;
revoke execute on function public.cancel_auction_listing(uuid) from public, anon;
revoke execute on function public.resolve_auction(uuid) from public, anon;
grant execute on function public.create_auction_listing(text, boolean, integer, integer) to authenticated;
grant execute on function public.place_bid(uuid, integer) to authenticated;
grant execute on function public.cancel_auction_listing(uuid) to authenticated;
grant execute on function public.resolve_auction(uuid) to authenticated;

-- ============================================================
-- FICHIER: 024_achievements_auction_win.sql
-- ============================================================
-- Ludodex Online — 024 : succès "Adjugé !" devient atteignable
-- Redéfinit sync_and_claim_achievements() et get_achievement_progress() (021) pour compter les
-- enchères remportées, maintenant que resolve_auction() (023) peut vraiment en produire.

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
  v_auctions_won integer;
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
  select count(*) into v_bought_count from public.market_listings where buyer_profile_id = v_profile and status = 'sold' and listing_type = 'sale';
  select count(*) into v_auctions_won from public.market_listings where buyer_profile_id = v_profile and status = 'sold' and listing_type = 'auction';
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
      ('win',  v_auctions_won, 1),
      ('raf',  0, 1) -- tombola pas encore implémentée : jamais atteint
  )
  insert into public.achievements_unlocked (profile_id, achievement_id)
  select v_profile, achievement_id from defs where val >= goal
  on conflict (profile_id, achievement_id) do nothing;

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
  v_auctions_won integer;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile;
  select count(distinct card_id) into v_owned_distinct from public.collection where profile_id = v_profile;
  select count(*) into v_catalogue_total from public.card_catalogue;
  select count(*) into v_sold_count from public.market_listings where seller_profile_id = v_profile and status = 'sold';
  select count(*) into v_bought_count from public.market_listings where buyer_profile_id = v_profile and status = 'sold' and listing_type = 'sale';
  select count(*) into v_auctions_won from public.market_listings where buyer_profile_id = v_profile and status = 'sold' and listing_type = 'auction';
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
    'auctions_won', v_auctions_won,
    'earned', v_earned
  );
end;
$$;

-- ============================================================
-- FICHIER: 025_themed_boosters.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 026_raffle.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 027_discard_values_low.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 028_profiles_username_case_insensitive.sql
-- ============================================================
-- Ludodex Online — 028 : unicité du pseudo insensible à la casse
-- La contrainte `username text unique not null` de 002_profiles.sql est sensible à la casse :
-- "Doktor" et "doktor" pouvaient coexister. Décision prise avec l'utilisateur : deux pseudos qui
-- ne diffèrent que par la casse sont désormais refusés (évite la confusion/usurpation sur le
-- marché et le chat). L'ancienne contrainte reste en place (redondante mais inoffensive) ; cet
-- index unique sur lower(username) est la règle qui compte réellement désormais.

drop index if exists public.profiles_username_ci_key;
create unique index profiles_username_ci_key on public.profiles (lower(username));

-- ============================================================
-- FICHIER: 029_notifications.sql
-- ============================================================
-- Ludodex Online — 029 : notifications (table + fonction interne de création)
-- Une notification par événement utile au joueur (succès débloqué, mise dépassée, enchère
-- gagnée, carte vendue, message reçu...). link_type/link_id disent au client où emmener le
-- joueur au clic (ex. link_type='listing', link_id=<uuid du market_listings> pour ouvrir le bon
-- onglet du Marché ; link_type='message', link_id=<profile_id de l'autre> pour ouvrir la
-- conversation). Écriture réservée aux fonctions serveur (create_notification, appelée en interne
-- par les RPC de succès/marché et par le trigger sur private_messages, jamais par le client
-- directement) — seule la lecture et le passage à "lu" sont ouverts au propriétaire.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  link_type text,
  link_id text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_profile_recent_idx
  on public.notifications (profile_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "notifications_select_own" on public.notifications;
create policy "notifications_select_own"
  on public.notifications for select
  using (auth.uid() = profile_id);

-- Le propriétaire peut seulement la marquer lue/non lue depuis son client (pas de risque à lui
-- laisser aussi réécrire titre/texte de ce qu'il voit déjà : simplification assumée, cette table
-- n'est pas une source de vérité pour l'état du jeu, juste un fil d'annonces).
drop policy if exists "notifications_update_own" on public.notifications;
create policy "notifications_update_own"
  on public.notifications for update
  using (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

create or replace function public.create_notification(
  p_profile uuid, p_type text, p_title text, p_body text, p_link_type text, p_link_id text
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.notifications (profile_id, type, title, body, link_type, link_id)
  values (p_profile, p_type, p_title, p_body, p_link_type, p_link_id);
$$;

-- ============================================================
-- FICHIER: 030_notify_market_achievements.sql
-- ============================================================
-- Ludodex Online — 030 : notifications déclenchées par le marché et les succès
-- Redéfinit (create or replace, sûr) place_bid/resolve_auction/buy_listing (023/020) et
-- sync_and_claim_achievements (021) pour appeler create_notification (029) aux moments utiles :
-- mise dépassée, enchère gagnée, carte vendue (vente directe ou enchère), succès débloqué.
-- link_type='listing' → le client ouvre listing.html?id=<link_id> (page de détail d'une annonce,
-- garde l'historique complet des mises indéfiniment) ; link_type='achievement' → achievements.html.

create or replace function public.place_bid(p_listing_id uuid, p_amount integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_listing public.market_listings%rowtype;
  v_top_bid integer;
  v_top_bidder uuid;
  v_min_next integer;
  v_bidder_coins integer;
  v_title text;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.listing_type <> 'auction' then
    raise exception 'Cette annonce n''est pas une enchère.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'Cette enchère n''est plus active.';
  end if;
  if v_listing.ends_at <= now() then
    raise exception 'Cette enchère est terminée.';
  end if;
  if v_listing.seller_type = 'player' and v_listing.seller_profile_id = v_profile then
    raise exception 'Tu ne peux pas enchérir sur ta propre annonce.';
  end if;

  select amount, bidder_profile_id into v_top_bid, v_top_bidder
    from public.market_bids where listing_id = p_listing_id order by amount desc limit 1;
  v_min_next := coalesce(v_top_bid + greatest(1, round(v_top_bid * 0.07)), v_listing.price);
  if p_amount < v_min_next then
    raise exception 'Mise minimale : %.', v_min_next;
  end if;

  select coins into v_bidder_coins from public.player_state where profile_id = v_profile;
  if v_bidder_coins is null or v_bidder_coins < p_amount then
    raise exception 'Pas assez de pièces pour cette mise.';
  end if;

  insert into public.market_bids (listing_id, bidder_type, bidder_profile_id, amount)
    values (p_listing_id, 'player', v_profile, p_amount);

  if v_top_bidder is not null and v_top_bidder <> v_profile then
    select title into v_title from public.card_catalogue where card_id = v_listing.card_id;
    perform public.create_notification(
      v_top_bidder, 'outbid', 'Mise dépassée',
      coalesce(v_title, 'Une carte') || ' : quelqu''un a misé plus haut que toi (' || p_amount || ' pièces).',
      'listing', p_listing_id::text
    );
  end if;
end;
$$;

create or replace function public.resolve_auction(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.market_listings%rowtype;
  v_bid record;
  v_winner_coins integer;
  v_resolved boolean := false;
  v_title text;
begin
  select * into v_listing from public.market_listings where id = p_listing_id for update;
  if not found then
    raise exception 'Annonce introuvable.';
  end if;
  if v_listing.listing_type <> 'auction' or v_listing.status <> 'active' then
    return; -- déjà résolue ou n'est pas une enchère : rien à faire, pas une erreur
  end if;
  if v_listing.ends_at > now() then
    raise exception 'Cette enchère n''est pas encore terminée.';
  end if;

  select title into v_title from public.card_catalogue where card_id = v_listing.card_id;

  for v_bid in
    select * from public.market_bids
    where listing_id = p_listing_id
    order by amount desc, created_at asc
  loop
    select coins into v_winner_coins from public.player_state where profile_id = v_bid.bidder_profile_id for update;
    if v_winner_coins is not null and v_winner_coins >= v_bid.amount then
      update public.market_listings set status = 'sold', buyer_profile_id = v_bid.bidder_profile_id where id = p_listing_id;
      update public.player_state set coins = coins - v_bid.amount, updated_at = now() where profile_id = v_bid.bidder_profile_id;
      if v_listing.seller_type = 'player' then
        update public.player_state set coins = coins + v_bid.amount, updated_at = now() where profile_id = v_listing.seller_profile_id;
      end if;
      insert into public.collection (profile_id, card_id, shiny, count)
        values (v_bid.bidder_profile_id, v_listing.card_id, v_listing.shiny, 1)
        on conflict (profile_id, card_id, shiny)
        do update set count = public.collection.count + 1;

      perform public.create_notification(
        v_bid.bidder_profile_id, 'auction_won', 'Enchère remportée',
        'Tu as remporté ' || coalesce(v_title, 'une carte') || ' pour ' || v_bid.amount || ' pièces.',
        'listing', p_listing_id::text
      );
      if v_listing.seller_type = 'player' then
        perform public.create_notification(
          v_listing.seller_profile_id, 'listing_sold', 'Carte vendue',
          coalesce(v_title, 'Ta carte') || ' s''est vendue aux enchères pour ' || v_bid.amount || ' pièces.',
          'listing', p_listing_id::text
        );
      end if;

      v_resolved := true;
      exit;
    end if;
  end loop;

  if not v_resolved then
    -- Aucune offre valide (ou aucune offre du tout) : la carte revient au vendeur.
    update public.market_listings set status = 'cancelled' where id = p_listing_id;
    if v_listing.seller_type = 'player' then
      insert into public.collection (profile_id, card_id, shiny, count)
        values (v_listing.seller_profile_id, v_listing.card_id, v_listing.shiny, 1)
        on conflict (profile_id, card_id, shiny)
        do update set count = public.collection.count + 1;
    end if;
  end if;
end;
$$;

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
  v_title text;
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

  if v_listing.seller_type = 'player' then
    select title into v_title from public.card_catalogue where card_id = v_listing.card_id;
    perform public.create_notification(
      v_listing.seller_profile_id, 'listing_sold', 'Carte vendue',
      coalesce(v_title, 'Ta carte') || ' s''est vendue pour ' || v_listing.price || ' pièces.',
      'listing', p_listing_id::text
    );
  end if;
end;
$$;

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

  -- Récupération : verse la récompense de chaque succès débloqué pas encore payé, et notifie.
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
    perform public.create_notification(
      v_profile, 'achievement', 'Succès débloqué',
      'Récompense : ' || rec.reward || ' pièces.',
      'achievement', rec.achievement_id
    );
  end loop;

  if v_total_reward > 0 then
    update public.player_state set coins = coins + v_total_reward, updated_at = now() where profile_id = v_profile;
  end if;

  return jsonb_build_object('granted', v_granted, 'total_reward', v_total_reward);
end;
$$;

-- ============================================================
-- FICHIER: 031_notify_messages.sql
-- ============================================================
-- Ludodex Online — 031 : notification à la réception d'un message privé
-- private_messages est écrite directement par le client (pas de RPC, voir 007), donc on ne peut
-- pas insérer la notification "à la main" dans une fonction serveur comme pour le marché/succès :
-- un trigger AFTER INSERT s'en charge. link_id = l'expéditeur, pour que le client ouvre
-- directement la conversation avec lui (messages.html?with=<profile_id>).

create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender text;
begin
  select username into v_sender from public.profiles where id = new.sender_id;
  perform public.create_notification(
    new.recipient_id, 'message', 'Nouveau message',
    coalesce(v_sender, 'Un joueur') || ' t''a envoyé un message.',
    'message', new.sender_id::text
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_new_message on public.private_messages;
create trigger trg_notify_new_message
  after insert on public.private_messages
  for each row execute function public.notify_new_message();

-- ============================================================
-- FICHIER: 032_trade_offers.sql
-- ============================================================
-- Ludodex Online — 032 : échanges joueur-à-joueur (table)
-- Remplace la démo locale de social.html (négociation simulée avec des amis inventés) par de
-- vrais échanges entre deux comptes réels. Cartes stockées en jsonb ([{card_id,shiny,count}, ...])
-- plutôt qu'une table de jonction : plus simple à valider d'un bloc dans les RPC (033), et la
-- liste ne sert qu'à décrire une proposition, jamais interrogée carte par carte ailleurs.
-- Modèle retenu, identique au marché (014/023) : proposer une offre RETIRE immédiatement les
-- cartes offertes de la collection du proposeur (séquestre), pour empêcher de les revendre ou
-- défausser pendant que la proposition est en attente. Rendues si refusée/annulée.

create table if not exists public.trade_offers (
  id uuid primary key default gen_random_uuid(),
  from_profile uuid not null references public.profiles(id) on delete cascade,
  to_profile uuid not null references public.profiles(id) on delete cascade,
  offered jsonb not null,
  requested jsonb not null,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  constraint trade_offers_status_check check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  constraint trade_offers_not_self check (from_profile <> to_profile)
);

create index if not exists trade_offers_to_profile_idx on public.trade_offers (to_profile, status, created_at desc);
create index if not exists trade_offers_from_profile_idx on public.trade_offers (from_profile, created_at desc);

alter table public.trade_offers enable row level security;

drop policy if exists "trade_offers_select_participants" on public.trade_offers;
create policy "trade_offers_select_participants"
  on public.trade_offers for select
  using (auth.uid() = from_profile or auth.uid() = to_profile);

-- Volontairement aucune policy insert/update/delete : proposer/répondre/annuler passe par les RPC
-- de 033_rpc_trades.sql, qui déplacent réellement les cartes de façon atomique et vérifiée.

-- ============================================================
-- FICHIER: 033_rpc_trades.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 034_duels.sql
-- ============================================================
-- Ludodex Online — 034 : duels contre l'ordinateur (table historique + colonnes player_state)
-- Reprend le principe déjà validé dans PROMPT_REPRISE.md/social.html : deck de 5 cartes, chacune
-- comparée à un adversaire généré aléatoirement dans card_catalogue À LA MÊME RARETÉ (pas de vrai
-- PvP entre comptes, comme dans la démo), 5 duels/jour max, victoire = ATK-DEF le plus favorable.
-- duel_history est conservé indéfiniment (comme market_listings/market_bids) : chaque duel reste
-- consultable en détail via sa propre page (voir 035_rpc_run_duel.sql pour la fonction).

alter table public.player_state
  add column if not exists duel_date date,
  add column if not exists duels_played_today integer not null default 0,
  add column if not exists duel_wins_total integer not null default 0;

create table if not exists public.duel_history (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  won boolean not null,
  my_wins integer not null,
  their_wins integer not null,
  reward integer not null,
  rounds jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists duel_history_profile_idx on public.duel_history (profile_id, created_at desc);

alter table public.duel_history enable row level security;

drop policy if exists "duel_history_select_own" on public.duel_history;
create policy "duel_history_select_own"
  on public.duel_history for select
  using (auth.uid() = profile_id);

-- Volontairement aucune policy insert/update/delete : uniquement écrit par run_duel() (035).

-- ============================================================
-- FICHIER: 035_rpc_run_duel.sql
-- ============================================================
-- Ludodex Online — 035 : run_duel() — résout un duel de 5 cartes contre l'ordinateur
-- Reproduit site/js/engine social.js (runDuel/pickOpponentFor) : chaque carte du deck du joueur
-- affronte une carte adverse tirée au hasard dans card_catalogue à la MÊME rareté, ATK contre DEF
-- dans les deux sens, la marge la plus élevée gagne la manche. Récompense identique à la démo :
-- 40 + 10 par manche gagnée si victoire globale, sinon 10 (25 % de consolation).

create or replace function public.run_duel(p_deck text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_card_id text;
  v_card record;
  v_opponent record;
  v_my_wins integer := 0;
  v_their_wins integer := 0;
  v_rounds jsonb := '[]'::jsonb;
  v_result text;
  v_won boolean;
  v_reward integer;
  v_duel_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_deck is null or array_length(p_deck, 1) <> 5 then
    raise exception 'Le deck doit contenir exactement 5 cartes.';
  end if;
  if array_length(p_deck, 1) <> (select count(distinct x) from unnest(p_deck) x) then
    raise exception 'Chaque carte du deck doit être différente.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  if v_state.duel_date is distinct from current_date then
    update public.player_state set duel_date = current_date, duels_played_today = 0
      where profile_id = v_profile;
    v_state.duels_played_today := 0;
  end if;
  if v_state.duels_played_today >= 5 then
    raise exception 'Plus de duels disponibles aujourd''hui.';
  end if;

  foreach v_card_id in array p_deck loop
    if not exists (
      select 1 from public.collection
      where profile_id = v_profile and card_id = v_card_id and count > 0
    ) then
      raise exception 'Tu ne possèdes pas la carte %.', v_card_id;
    end if;

    select card_id, title, atk, def, rarity into v_card
      from public.card_catalogue where card_id = v_card_id;

    select card_id, title, atk, def into v_opponent
      from public.card_catalogue
      where rarity = v_card.rarity and card_id <> v_card.card_id
      order by random() limit 1;
    if not found then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity
        order by random() limit 1;
    end if;

    if (v_card.atk - v_opponent.def) > (v_opponent.atk - v_card.def) then
      v_result := 'win'; v_my_wins := v_my_wins + 1;
    elsif (v_opponent.atk - v_card.def) > (v_card.atk - v_opponent.def) then
      v_result := 'lose'; v_their_wins := v_their_wins + 1;
    else
      v_result := 'draw';
    end if;

    v_rounds := v_rounds || jsonb_build_object(
      'my_card_id', v_card.card_id, 'my_title', v_card.title, 'my_atk', v_card.atk,
      'opp_card_id', v_opponent.card_id, 'opp_title', v_opponent.title, 'opp_def', v_opponent.def,
      'result', v_result
    );
  end loop;

  v_won := v_my_wins > v_their_wins;
  v_reward := case when v_won then 40 + v_my_wins * 10 else round(40 * 0.25) end;

  update public.player_state set
    coins = coins + v_reward,
    duels_played_today = duels_played_today + 1,
    duel_wins_total = duel_wins_total + (case when v_won then 1 else 0 end),
    updated_at = now()
  where profile_id = v_profile;

  insert into public.duel_history (profile_id, won, my_wins, their_wins, reward, rounds)
    values (v_profile, v_won, v_my_wins, v_their_wins, v_reward, v_rounds)
    returning id into v_duel_id;

  perform public.create_notification(
    v_profile, 'duel_result',
    case when v_won then 'Duel gagné' else 'Duel perdu' end,
    v_my_wins || ' - ' || v_their_wins || ' · +' || v_reward || ' pièces.',
    'duel', v_duel_id::text
  );

  return jsonb_build_object(
    'id', v_duel_id, 'won', v_won, 'my_wins', v_my_wins, 'their_wins', v_their_wins,
    'reward', v_reward, 'rounds', v_rounds
  );
end;
$$;

revoke execute on function public.run_duel(text[]) from public, anon;
grant execute on function public.run_duel(text[]) to authenticated;

-- ============================================================
-- FICHIER: 036_card_catalogue_descriptions.sql
-- ============================================================
-- Ludodex Online — 036 : bio multilingue des cartes + genres en repli
-- card_catalogue était volontairement léger jusqu'ici (voir 015 : pas de vraie bio en base, la
-- fiche détail affichait développeur/plateforme/année à la place). Ajout de colonnes de résumé
-- par langue, remplies séparément via un import CSV (voir outils_igdb/fetch_descriptions.py +
-- translate_descriptions.py, propriété Codex) — pas de traduction faite ici, juste la place pour
-- les recevoir. NULL tant qu'aucun résumé IGDB n'existe pour ce jeu (beaucoup n'en ont pas) : le
-- client doit prévoir ce cas, pas en faire une erreur.
-- `genres` : repli d'affichage quand il n'y a ni description_en ni description_fr — les genres
-- IGDB (ex. "Shooter, Indie, Arcade") sont déjà présents dans les fichiers data/ mais jamais
-- importés jusqu'ici (generate_card_catalogue.js les ignorait). Stocké en texte simple, déjà
-- joint par virgule, pour rester cohérent avec le reste de card_catalogue (pas de colonne array).

alter table public.card_catalogue
  add column if not exists description_en text,
  add column if not exists description_fr text,
  add column if not exists genres text;

-- ============================================================
-- FICHIER: 037_wishlist.sql
-- ============================================================
-- Ludodex Online — 037 : liste de souhaits
-- Un joueur ajoute une carte qu'il ne possède pas (n'importe laquelle des 203 000+ de
-- card_catalogue) ; voir 038_notify_wishlist.sql pour l'alerte à la mise en vente.

create table if not exists public.wishlist (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null references public.card_catalogue(card_id),
  created_at timestamptz not null default now(),
  primary key (profile_id, card_id)
);

create index if not exists wishlist_card_idx on public.wishlist (card_id);

alter table public.wishlist enable row level security;

drop policy if exists "wishlist_select_own" on public.wishlist;
create policy "wishlist_select_own"
  on public.wishlist for select
  using (auth.uid() = profile_id);

drop policy if exists "wishlist_insert_own" on public.wishlist;
create policy "wishlist_insert_own"
  on public.wishlist for insert
  with check (auth.uid() = profile_id);

drop policy if exists "wishlist_delete_own" on public.wishlist;
create policy "wishlist_delete_own"
  on public.wishlist for delete
  using (auth.uid() = profile_id);

-- ============================================================
-- FICHIER: 038_notify_wishlist.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 039_admin_bulk_update_card_catalogue.sql
-- ============================================================
-- Ludodex Online — 039 : mise à jour en masse de card_catalogue (colonnes de repli, admin only)
-- backfill_card_fields.js utilisait un upsert PostgREST classique (POST + Prefer:
-- resolution=merge-duplicates) : ça échoue avec "null value in column rarity violates not-null
-- constraint", parce que Postgres construit la ligne candidate pour ON CONFLICT DO UPDATE avant
-- de détecter le conflit, et exige donc les colonnes NOT NULL même si la ligne existe déjà et ne
-- sera jamais réellement insérée. Une vraie UPDATE (jamais d'INSERT) évite ce problème.
--
-- Restreint à trois colonnes de repli (whitelist), jamais accessible aux joueurs (pas de grant à
-- authenticated) : appelable uniquement avec la clé de service, qui bypasse les grants — c'est un
-- outil d'administration du catalogue, pas une action de jeu.

create or replace function public.admin_bulk_update_card_catalogue(p_column text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_column not in ('genres', 'description_en', 'description_fr') then
    raise exception 'Colonne non autorisée : %', p_column;
  end if;

  if p_column = 'genres' then
    update public.card_catalogue c set genres = r.value
      from jsonb_to_recordset(p_rows) as r(card_id text, value text)
      where c.card_id = r.card_id;
  elsif p_column = 'description_en' then
    update public.card_catalogue c set description_en = r.value
      from jsonb_to_recordset(p_rows) as r(card_id text, value text)
      where c.card_id = r.card_id;
  else
    update public.card_catalogue c set description_fr = r.value
      from jsonb_to_recordset(p_rows) as r(card_id text, value text)
      where c.card_id = r.card_id;
  end if;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.admin_bulk_update_card_catalogue(text, jsonb) from public, anon, authenticated;

-- ============================================================
-- FICHIER: 040_perf_random_card_pick.sql
-- ============================================================
-- Ludodex Online — 040 : ouverture de booster lente depuis l'élargissement du catalogue (×6)
-- Cause : open_booster() (019) tirait une carte avec `ORDER BY random() LIMIT 1`, qui oblige
-- Postgres à calculer une valeur aléatoire pour TOUTES les cartes de la rareté puis à les trier,
-- 5 fois par booster (une par carte). Avec 32 483 cartes ça passait à peu près ; avec 203 438
-- (dont 81 374 Commune à elles seules), c'est devenu net. Aucun index sur `rarity` non plus :
-- chaque tirage faisait un balayage séquentiel complet de la table en plus du tri.
--
-- Correctif : un index sur `rarity` (utile aussi pour cards.html : filtre par rareté, comptage
-- du résumé par rareté) + tirage par décalage aléatoire (compter les cartes de la rareté, tirer
-- un offset au hasard, lire une seule ligne à cet offset) au lieu de trier tout le monde. Compte
-- mis en cache en mémoire LE TEMPS D'UN SEUL appel de open_booster() (jusqu'à 5 tirages peuvent
-- viser la même rareté sur un même booster) — jamais persisté, la table change trop rarement pour
-- que ça vaille la peine.

create index if not exists card_catalogue_rarity_idx on public.card_catalogue (rarity);

-- `drop ... if exists` avant le `create or replace` : 047 redéfinit cette fonction avec un défaut
-- sur p_count (`int default null`) — Postgres refuse de RETIRER un défaut existant via un simple
-- `create or replace`, donc rejouer 040 après que 047 ait déjà tourné plantait sans ce drop
-- préalable (bug découvert le 28/09/2026 en rejouant les migrations).
drop function if exists public._pick_random_card(int, int);
create or replace function public._pick_random_card(p_rarity int, p_count int)
returns text
language plpgsql
as $$
declare
  v_card_id text;
begin
  if p_count <= 0 then
    return null;
  end if;
  select card_id into v_card_id
    from public.card_catalogue
    where rarity = p_rarity
    offset floor(random() * p_count)
    limit 1;
  return v_card_id;
end;
$$;

create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_now timestamptz := now();
  v_regen_ms constant bigint := 10 * 60 * 1000; -- REGEN_MS
  v_max_packs constant int := 10;               -- MAX_PACKS
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
  v_rarity_counts int[] := array[null, null, null, null, null, null]; -- cache par appel, index 0-5
  v_rarity_count int;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

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
  v_state.boosters_opened_total := v_state.boosters_opened_total + 1;
  if v_gold then
    v_state.golds_opened_total := v_state.golds_opened_total + 1;
  end if;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);

    if v_rarity_counts[v_rarity + 1] is null then
      select count(*) into v_rarity_count from public.card_catalogue where rarity = v_rarity;
      v_rarity_counts[v_rarity + 1] := v_rarity_count;
    end if;

    v_card_id := public._pick_random_card(v_rarity, v_rarity_counts[v_rarity + 1]);

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;
    if v_shiny then
      v_state.shiny_drawn_total := v_state.shiny_drawn_total + 1;
    end if;
    if v_rarity = 2 then v_state.pulls_rare := v_state.pulls_rare + 1;
    elsif v_rarity = 3 then v_state.pulls_epic := v_state.pulls_epic + 1;
    elsif v_rarity = 4 then v_state.pulls_legendary := v_state.pulls_legendary + 1;
    elsif v_rarity = 5 then v_state.pulls_mythic := v_state.pulls_mythic + 1;
    end if;

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
        boosters_opened_total = v_state.boosters_opened_total,
        golds_opened_total = v_state.golds_opened_total,
        shiny_drawn_total = v_state.shiny_drawn_total,
        pulls_rare = v_state.pulls_rare,
        pulls_epic = v_state.pulls_epic,
        pulls_legendary = v_state.pulls_legendary,
        pulls_mythic = v_state.pulls_mythic,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;

-- ============================================================
-- FICHIER: 041_perf_duel_opponent_pick.sql
-- ============================================================
-- Ludodex Online — 041 : même correctif de lenteur que 040, pour les duels
-- run_duel() (035) tirait l'adversaire de chaque carte avec `ORDER BY random() LIMIT 1` sur
-- card_catalogue filtré par rareté — même anti-pattern que open_booster(), même cause (catalogue
-- ×6), même correctif (compter puis lire à un offset aléatoire, index déjà ajouté par 040).

create or replace function public.run_duel(p_deck text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_card_id text;
  v_card record;
  v_opponent record;
  v_my_wins integer := 0;
  v_their_wins integer := 0;
  v_rounds jsonb := '[]'::jsonb;
  v_result text;
  v_won boolean;
  v_reward integer;
  v_duel_id uuid;
  v_rarity_count int;
  v_opp_offset int;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_deck is null or array_length(p_deck, 1) <> 5 then
    raise exception 'Le deck doit contenir exactement 5 cartes.';
  end if;
  if array_length(p_deck, 1) <> (select count(distinct x) from unnest(p_deck) x) then
    raise exception 'Chaque carte du deck doit être différente.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  if v_state.duel_date is distinct from current_date then
    update public.player_state set duel_date = current_date, duels_played_today = 0
      where profile_id = v_profile;
    v_state.duels_played_today := 0;
  end if;
  if v_state.duels_played_today >= 5 then
    raise exception 'Plus de duels disponibles aujourd''hui.';
  end if;

  foreach v_card_id in array p_deck loop
    if not exists (
      select 1 from public.collection
      where profile_id = v_profile and card_id = v_card_id and count > 0
    ) then
      raise exception 'Tu ne possèdes pas la carte %.', v_card_id;
    end if;

    select card_id, title, atk, def, rarity into v_card
      from public.card_catalogue where card_id = v_card_id;

    -- Tirage par décalage aléatoire (voir 040) plutôt que ORDER BY random() sur toute la
    -- rareté : -1 pour exclure sa propre carte du décompte, repli sur elle-même si elle est la
    -- seule de sa rareté (count = 1).
    select count(*) into v_rarity_count from public.card_catalogue where rarity = v_card.rarity;
    if v_rarity_count > 1 then
      v_opp_offset := floor(random() * (v_rarity_count - 1));
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue
        where rarity = v_card.rarity and card_id <> v_card.card_id
        offset v_opp_offset limit 1;
    else
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity limit 1;
    end if;

    if (v_card.atk - v_opponent.def) > (v_opponent.atk - v_card.def) then
      v_result := 'win'; v_my_wins := v_my_wins + 1;
    elsif (v_opponent.atk - v_card.def) > (v_card.atk - v_opponent.def) then
      v_result := 'lose'; v_their_wins := v_their_wins + 1;
    else
      v_result := 'draw';
    end if;

    v_rounds := v_rounds || jsonb_build_object(
      'my_card_id', v_card.card_id, 'my_title', v_card.title, 'my_atk', v_card.atk,
      'opp_card_id', v_opponent.card_id, 'opp_title', v_opponent.title, 'opp_def', v_opponent.def,
      'result', v_result
    );
  end loop;

  v_won := v_my_wins > v_their_wins;
  v_reward := case when v_won then 40 + v_my_wins * 10 else round(40 * 0.25) end;

  update public.player_state set
    coins = coins + v_reward,
    duels_played_today = duels_played_today + 1,
    duel_wins_total = duel_wins_total + (case when v_won then 1 else 0 end),
    updated_at = now()
  where profile_id = v_profile;

  insert into public.duel_history (profile_id, won, my_wins, their_wins, reward, rounds)
    values (v_profile, v_won, v_my_wins, v_their_wins, v_reward, v_rounds)
    returning id into v_duel_id;

  perform public.create_notification(
    v_profile, 'duel_result',
    case when v_won then 'Duel gagné' else 'Duel perdu' end,
    v_my_wins || ' - ' || v_their_wins || ' · +' || v_reward || ' pièces.',
    'duel', v_duel_id::text
  );

  return jsonb_build_object(
    'id', v_duel_id, 'won', v_won, 'my_wins', v_my_wins, 'their_wins', v_their_wins,
    'reward', v_reward, 'rounds', v_rounds
  );
end;
$$;

-- ============================================================
-- FICHIER: 042_gold_unique_cards.sql
-- ============================================================
-- Ludodex Online — 042 : cartes Gold uniques (un seul exemplaire dans tout le jeu)
-- Volontairement SÉPARÉ de `collection` (pas une variante comme `shiny`, décision utilisateur du
-- 27/09/2026) : une carte Gold n'entre jamais dans le marché/échanges/défausse pour l'instant, ne
-- touche donc AUCUNE des ~10 fonctions déjà construites autour de `collection`. Juste un registre
-- global : la clé primaire sur card_id garantit qu'un jeu ne peut avoir qu'UN SEUL propriétaire
-- Gold dans tout Ludodex Online, jamais deux, même en cas de tirages simultanés (contrainte au
-- niveau base, pas juste vérifiée côté application).

create table if not exists public.gold_claims (
  card_id text primary key references public.card_catalogue(card_id),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  claimed_at timestamptz not null default now()
);

create index if not exists gold_claims_profile_idx on public.gold_claims (profile_id, claimed_at desc);

alter table public.gold_claims enable row level security;

-- Public comme card_catalogue/market_listings : "qui possède quelle carte Gold" fait partie du
-- prestige de la carte, pas une donnée privée.
drop policy if exists "gold_claims_select_all" on public.gold_claims;
create policy "gold_claims_select_all"
  on public.gold_claims for select
  using (true);

-- Volontairement aucune policy insert/update/delete pour authenticated : uniquement écrit par
-- open_booster() (043), qui vérifie déjà l'authentification et gère la course en cas de tirage
-- simultané via la contrainte de clé primaire (exception unique_violation attrapée).

-- ============================================================
-- FICHIER: 043_rpc_open_booster_gold.sql
-- ============================================================
-- Ludodex Online — 043 : chance infime de carte Gold unique à l'ouverture d'un booster
-- Redéfinit open_booster() (040) pour ajouter, APRÈS les 5 cartes normales (ne remplace aucun
-- tirage existant, ne touche pas aux poids de rareté), une chance bonus ultra faible de
-- remporter une carte Gold : un jeu console (PC/Mac/Linux/mobile/web/VR/cloud exclus, voir
-- v_console_exclusions) tiré parmi ceux qui n'ont PAS ENCORE de propriétaire Gold
-- (public.gold_claims, 042). Taux volontairement "de fou" (v_gold_rate) : bien plus bas que
-- Mythique (2 % par carte). Si deux joueurs déclenchent ce tirage à la même microseconde pour le
-- même jeu, la clé primaire de gold_claims tranche : le second reçoit une exception
-- unique_violation, silencieusement absorbée (pas de carte Gold ce tirage-ci pour lui, aucune
-- erreur visible côté client — un booster ne doit jamais échouer à cause d'un bonus raté).

create or replace function public.open_booster()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_now timestamptz := now();
  v_regen_ms constant bigint := 10 * 60 * 1000; -- REGEN_MS
  v_max_packs constant int := 10;               -- MAX_PACKS
  v_gold_every constant int := 10;              -- GOLD_EVERY (booster doré, sans rapport avec Gold unique)
  v_shiny_rate constant numeric := 1.0 / 20;    -- SHINY_RATE
  v_gold_rate constant numeric := 1.0 / 20000;  -- taux d'une carte Gold UNIQUE par booster ouvert
  v_gained bigint;
  v_gold boolean;
  v_weights numeric[];
  v_results jsonb := '[]'::jsonb;
  v_card_id text;
  v_rarity int;
  v_shiny boolean;
  s int;
  v_rarity_counts int[] := array[null, null, null, null, null, null];
  v_rarity_count int;
  v_gold_card_id text;
  v_gold_title text;
  v_console_exclusions constant text[] := array[
    'PC (Microsoft Windows)', 'Mac', 'Linux', 'DOS',
    'iOS', 'Android', 'Windows Phone', 'BlackBerry OS', 'Legacy Mobile Device', 'Windows Mobile',
    'Web browser',
    'SteamVR', 'Oculus Rift', 'Oculus VR', 'Oculus Quest', 'Oculus Go', 'PlayStation VR',
    'PlayStation VR2', 'Windows Mixed Reality', 'Meta Quest 2', 'Meta Quest 3', 'Gear VR',
    'Daydream', 'visionOS',
    'Google Stadia', 'OnLive Game System', 'Amazon Fire TV', 'Ouya',
    'DVD Player', 'Blu-ray Player', 'Palm OS', 'PLATO', 'Digiblast', 'Legacy Computer'
  ];
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

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
  v_state.boosters_opened_total := v_state.boosters_opened_total + 1;
  if v_gold then
    v_state.golds_opened_total := v_state.golds_opened_total + 1;
  end if;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);

    if v_rarity_counts[v_rarity + 1] is null then
      select count(*) into v_rarity_count from public.card_catalogue where rarity = v_rarity;
      v_rarity_counts[v_rarity + 1] := v_rarity_count;
    end if;

    v_card_id := public._pick_random_card(v_rarity, v_rarity_counts[v_rarity + 1]);

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;
    if v_shiny then
      v_state.shiny_drawn_total := v_state.shiny_drawn_total + 1;
    end if;
    if v_rarity = 2 then v_state.pulls_rare := v_state.pulls_rare + 1;
    elsif v_rarity = 3 then v_state.pulls_epic := v_state.pulls_epic + 1;
    elsif v_rarity = 4 then v_state.pulls_legendary := v_state.pulls_legendary + 1;
    elsif v_rarity = 5 then v_state.pulls_mythic := v_state.pulls_mythic + 1;
    end if;

    insert into public.collection (profile_id, card_id, shiny, count)
      values (v_profile, v_card_id, v_shiny, 1)
      on conflict (profile_id, card_id, shiny)
      do update set count = public.collection.count + 1;

    v_results := v_results || jsonb_build_object('card_id', v_card_id, 'rarity', v_rarity, 'shiny', v_shiny);
  end loop;

  -- Bonus Gold unique : indépendant des 5 cartes ci-dessus, ne consomme aucun slot.
  if random() < v_gold_rate then
    select card_id into v_gold_card_id
      from public.card_catalogue
      where platform_name <> all (v_console_exclusions)
        and card_id not in (select card_id from public.gold_claims)
      order by random()
      limit 1;

    if v_gold_card_id is not null then
      begin
        insert into public.gold_claims (card_id, profile_id) values (v_gold_card_id, v_profile);
        select title into v_gold_title from public.card_catalogue where card_id = v_gold_card_id;
        v_results := v_results || jsonb_build_object('card_id', v_gold_card_id, 'gold', true);
        perform public.create_notification(
          v_profile, 'gold_unique', '✨ Carte Gold unique !',
          'Tu es désormais le seul possesseur de ' || coalesce(v_gold_title, 'cette carte') || ' dans tout Ludodex.',
          null, null
        );
      exception when unique_violation then
        -- Un autre joueur l'a obtenue à la même microseconde : rien pour ce tirage-ci, pas d'erreur.
        null;
      end;
    end if;
  end if;

  if v_gold then
    v_state.opens_since_gold := 0;
  else
    v_state.opens_since_gold := v_state.opens_since_gold + 1;
  end if;

  update public.player_state
    set boosters_available = v_state.boosters_available,
        last_regen_at = v_state.last_regen_at,
        opens_since_gold = v_state.opens_since_gold,
        boosters_opened_total = v_state.boosters_opened_total,
        golds_opened_total = v_state.golds_opened_total,
        shiny_drawn_total = v_state.shiny_drawn_total,
        pulls_rare = v_state.pulls_rare,
        pulls_epic = v_state.pulls_epic,
        pulls_legendary = v_state.pulls_legendary,
        pulls_mythic = v_state.pulls_mythic,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;

-- ============================================================
-- FICHIER: 044_character_catalogue.sql
-- ============================================================
-- Ludodex Online — 044 : character_catalogue, table séparée de card_catalogue pour les
-- personnages de jeux vidéo (à distinguer des fiches "jeu" existantes). Démarre avec Animal
-- Crossing (566 fiches : 490 villageois + 76 personnages spéciaux, récupérés via l'API Cargo
-- publique de Nookipedia — voir schema/catalogue_import/generate_character_catalogue.js).
--
-- Séparée volontairement de card_catalogue : un personnage n'a pas de plateforme/année de sortie
-- unique (il apparaît dans plusieurs jeux), et rien ne dit encore si/comment ces fiches seront
-- mêlées aux boosters/collection existants — cette table n'est pour l'instant qu'un catalogue
-- consultable, aucune RPC de jeu n'y touche.
--
-- Même schéma de rareté que card_catalogue (percentile 0-5 calculé sur ce catalogue séparément),
-- même politique RLS (lecture publique, écriture réservée au rôle de service).

create table if not exists public.character_catalogue (
  character_id text primary key,
  franchise text not null,
  character_type text not null check (character_type in ('villager', 'special')),
  name text not null,
  species text,
  personality text,
  gender text,
  birthday text,
  quote text,
  games text,
  rarity smallint not null check (rarity between 0 and 5),
  rarity_name text not null,
  rarity_color text not null,
  family_color text not null,
  image_url text,
  atk integer not null,
  def integer not null,
  updated_at timestamptz not null default now()
);

create index if not exists character_catalogue_franchise_idx on public.character_catalogue (franchise);
create index if not exists character_catalogue_rarity_idx on public.character_catalogue (rarity);

alter table public.character_catalogue enable row level security;

drop policy if exists "character_catalogue_select_all" on public.character_catalogue;
create policy "character_catalogue_select_all"
  on public.character_catalogue for select
  using (true);

-- ============================================================
-- FICHIER: 045_character_catalogue_pokemon.sql
-- ============================================================
-- Ludodex Online — 045 : ouvre character_type à un deuxième franchise (Pokémon, 1 347 fiches :
-- formes standards + Méga-évolutions + Gigamax + formes régionales Alola/Galar/Hisui/Paldéa +
-- légendaires/mythiques, via l'export CSV public du dépôt GitHub PokeAPI/pokeapi, noms en
-- français). La contrainte de 044 ('villager'/'special') était propre à Animal Crossing —
-- generate_character_catalogue.js utilise maintenant des valeurs plus descriptives par
-- franchise (standard, legendary, mythical, mega, gmax, regional pour Pokémon), donc on l'élargit
-- au lieu de la garder figée à un seul jeu.
--
-- CORRIGÉ le 28/09/2026 (bug découvert en rejouant la migration) : la liste ci-dessous inclut
-- directement 'skin' (n'apparaît normalement qu'en 046, League of Legends) pour que ce fichier
-- reste rejouable même quand la table contient déjà des personnages League of Legends — sinon
-- l'ADD CONSTRAINT échoue en validant des lignes 'skin' déjà en base avec une liste trop étroite.
-- `drop constraint if exists` évite aussi l'échec si 045 a déjà tourné avant 046 dans le même lot.

alter table public.character_catalogue drop constraint if exists character_catalogue_character_type_check;
alter table public.character_catalogue add constraint character_catalogue_character_type_check
  check (character_type in ('villager', 'special', 'standard', 'legendary', 'mythical', 'mega', 'gmax', 'regional', 'skin'));

-- ============================================================
-- FICHIER: 046_character_catalogue_lol.sql
-- ============================================================
-- Ludodex Online — 046 : ouvre character_type à un troisième franchise (League of Legends,
-- 2 122 fiches : 173 champions + leurs skins non-chroma, via l'API officielle et gratuite Riot
-- Data Dragon, noms en français). Ajoute la valeur 'skin' à la contrainte de 045.
--
-- 045 a été corrigé le 28/09/2026 pour inclure 'skin' aussi (voir son en-tête) — ce fichier
-- redéfinit maintenant la même liste, ce qui est volontaire et sans risque (`if exists` +
-- `create/add` derrière une valeur identique = no-op).

alter table public.character_catalogue drop constraint if exists character_catalogue_character_type_check;
alter table public.character_catalogue add constraint character_catalogue_character_type_check
  check (character_type in ('villager', 'special', 'standard', 'legendary', 'mythical', 'mega', 'gmax', 'regional', 'skin'));

-- ============================================================
-- FICHIER: 047_perf_random_key.sql
-- ============================================================
-- Ludodex Online — 047 : le correctif de 040/041 (compter puis lire à un OFFSET aléatoire) était
-- une amélioration par rapport à `ORDER BY random() LIMIT 1`, mais reste O(n) : Postgres doit
-- quand même parcourir séquentiellement les lignes jusqu'à l'offset tiré (jusqu'à ~78 000 lignes
-- pour la rareté Commune). Après la purge de 8 362 fiches à contenu adulte + les ajouts récents
-- (comblement plateforme, flops AAA), ce parcours dépasse le timeout Postgres ("canceling
-- statement due to statement timeout") à l'ouverture d'un booster — signalé par l'utilisateur.
--
-- Correctif définitif : une colonne `random_key` (valeur aléatoire figée à l'insertion, pas
-- recalculée à chaque appel) + un index sur `(rarity, random_key)`. Le tirage devient une
-- recherche par plage indexée (`WHERE rarity = X AND random_key >= seuil ORDER BY random_key
-- LIMIT 1`, avec repli en cas de dépassement de la plage) — un vrai accès O(log n), qui reste
-- rapide quelle que soit la taille du catalogue ou le volume de lignes mortes en attente de
-- VACUUM. Remplace complètement le mécanisme de comptage+offset de 040/041.

alter table public.card_catalogue add column if not exists random_key double precision not null default random();
drop index if exists public.card_catalogue_rarity_idx; -- remplacé par l'index composite ci-dessous
create index if not exists card_catalogue_rarity_random_idx on public.card_catalogue (rarity, random_key);

create or replace function public._pick_random_card(p_rarity int, p_count int default null)
returns text
language plpgsql
as $$
declare
  v_card_id text;
  v_threshold double precision := random();
begin
  select card_id into v_card_id
    from public.card_catalogue
    where rarity = p_rarity and random_key >= v_threshold
    order by random_key
    limit 1;

  if v_card_id is null then
    -- le seuil tiré dépassait la plus grande random_key de cette rareté : repli en repartant du
    -- début (équivalent d'un "wrap around"), toujours indexé.
    select card_id into v_card_id
      from public.card_catalogue
      where rarity = p_rarity
      order by random_key
      limit 1;
  end if;

  return v_card_id;
end;
$$;

create or replace function public.run_duel(p_deck text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_card_id text;
  v_card record;
  v_opponent record;
  v_my_wins integer := 0;
  v_their_wins integer := 0;
  v_rounds jsonb := '[]'::jsonb;
  v_result text;
  v_won boolean;
  v_reward integer;
  v_duel_id uuid;
  v_threshold double precision;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  if p_deck is null or array_length(p_deck, 1) <> 5 then
    raise exception 'Le deck doit contenir exactement 5 cartes.';
  end if;
  if array_length(p_deck, 1) <> (select count(distinct x) from unnest(p_deck) x) then
    raise exception 'Chaque carte du deck doit être différente.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  if v_state.duel_date is distinct from current_date then
    update public.player_state set duel_date = current_date, duels_played_today = 0
      where profile_id = v_profile;
    v_state.duels_played_today := 0;
  end if;
  if v_state.duels_played_today >= 5 then
    raise exception 'Plus de duels disponibles aujourd''hui.';
  end if;

  foreach v_card_id in array p_deck loop
    if not exists (
      select 1 from public.collection
      where profile_id = v_profile and card_id = v_card_id and count > 0
    ) then
      raise exception 'Tu ne possèdes pas la carte %.', v_card_id;
    end if;

    select card_id, title, atk, def, rarity into v_card
      from public.card_catalogue where card_id = v_card_id;

    -- Tirage indexé par plage (voir 047) plutôt que comptage+offset (040/041) : exclut sa propre
    -- carte, repli en fin de plage puis repli final sur soi-même si elle est la seule de sa
    -- rareté (aucune autre ligne ne peut alors matcher `card_id <> v_card.card_id`).
    v_threshold := random();
    select card_id, title, atk, def into v_opponent
      from public.card_catalogue
      where rarity = v_card.rarity and card_id <> v_card.card_id and random_key >= v_threshold
      order by random_key
      limit 1;

    if v_opponent is null then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue
        where rarity = v_card.rarity and card_id <> v_card.card_id
        order by random_key
        limit 1;
    end if;

    if v_opponent is null then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity limit 1;
    end if;

    if (v_card.atk - v_opponent.def) > (v_opponent.atk - v_card.def) then
      v_result := 'win'; v_my_wins := v_my_wins + 1;
    elsif (v_opponent.atk - v_card.def) > (v_card.atk - v_opponent.def) then
      v_result := 'lose'; v_their_wins := v_their_wins + 1;
    else
      v_result := 'draw';
    end if;

    v_rounds := v_rounds || jsonb_build_object(
      'my_card_id', v_card.card_id, 'my_title', v_card.title, 'my_atk', v_card.atk,
      'opp_card_id', v_opponent.card_id, 'opp_title', v_opponent.title, 'opp_def', v_opponent.def,
      'result', v_result
    );
  end loop;

  v_won := v_my_wins > v_their_wins;
  v_reward := case when v_won then 40 + v_my_wins * 10 else round(40 * 0.25) end;

  update public.player_state set
    coins = coins + v_reward,
    duels_played_today = duels_played_today + 1,
    duel_wins_total = duel_wins_total + (case when v_won then 1 else 0 end),
    updated_at = now()
  where profile_id = v_profile;

  insert into public.duel_history (profile_id, won, my_wins, their_wins, reward, rounds)
    values (v_profile, v_won, v_my_wins, v_their_wins, v_reward, v_rounds)
    returning id into v_duel_id;

  perform public.create_notification(
    v_profile, 'duel_result',
    case when v_won then 'Duel gagné' else 'Duel perdu' end,
    v_my_wins || ' - ' || v_their_wins || ' · +' || v_reward || ' pièces.',
    'duel', v_duel_id::text
  );

  return jsonb_build_object(
    'id', v_duel_id, 'won', v_won, 'my_wins', v_my_wins, 'their_wins', v_their_wins,
    'reward', v_reward, 'rounds', v_rounds
  );
end;
$$;

-- ============================================================
-- FICHIER: 048_all_cards_view.sql
-- ============================================================
-- Ludodex Online — 048 : vue unifiée jeux + personnages pour "Toutes les cartes" (web/cards.html).
-- Décision utilisateur : les personnages (character_catalogue) rejoignent le même écran de
-- parcours que les jeux (card_catalogue), pas une page séparée — juste un filtre en plus, sans
-- surcharger l'interface.
--
-- `card_id` reste le nom de colonne (alias de `character_id` côté personnages) pour ne rien
-- changer côté client : detail.js, la liste de souhaits, lastBatch etc. utilisent déjà ce nom.
-- `platform_name` porte la plateforme pour un jeu, la franchise pour un personnage (même usage à
-- l'affichage : ligne "développeur · plateforme/franchise · année" sous le titre). `genres` porte
-- un repli texte (espèce/rôle du personnage) pour que la bio affiche quelque chose de pertinent
-- même sans description longue (même logique de repli que card_catalogue, voir detail.js).
-- `kind` ('game'/'character') distingue les deux à l'affichage (actions/marché/liste de souhaits
-- n'existent que pour les jeux, voir web/js/detail.js) et sert de filtre principal côté UI.
--
-- Vue simple (pas de security barrier nécessaire) : elle hérite du RLS des deux tables sources,
-- toutes deux déjà en lecture publique.

create or replace view public.all_cards_catalogue as
select
  card_id, 'game'::text as kind, title, platform_name, year, developer, image_url,
  rarity, rarity_name, rarity_color, family_color, atk, def,
  description_en, description_fr, genres
from public.card_catalogue
union all
select
  character_id as card_id, 'character'::text as kind, name as title, franchise as platform_name,
  null::integer as year, null::text as developer, image_url,
  rarity, rarity_name, rarity_color, family_color, atk, def,
  null::text as description_en, null::text as description_fr,
  coalesce(species, quote) as genres
from public.character_catalogue;

grant select on public.all_cards_catalogue to anon, authenticated;

-- ============================================================
-- FICHIER: 049_notification_preferences.sql
-- ============================================================
-- Ludodex Online — 049 : préférences de notifications
-- Le joueur choisit quels types de notifications il reçoit (Profil > Notifications). Colonne JSON
-- sur profiles plutôt qu'une table à part : une poignée de booléens par joueur, jamais interrogée
-- indépendamment du profil, pas besoin d'une jointure en plus. Modèle opt-out : `{}` (défaut,
-- comportement actuel inchangé pour tous les comptes existants) = tout activé ; une clé absente
-- ou à `true` = activé, seule une clé explicitement à `false` désactive ce type. Types valides :
-- voir notifIcon() dans web/js/notifications.js (achievement, outbid, auction_won, listing_sold,
-- message, trade_offer, trade_accepted, trade_declined, duel_result, wishlist_available,
-- gold_unique).

alter table public.profiles
  add column if not exists notif_prefs jsonb not null default '{}'::jsonb;

-- Déjà modifiable par le joueur via la policy "profiles_update_own_non_role_fields" (002) : pas de
-- nouvelle policy nécessaire, ce n'est pas un champ sensible comme `role`.

-- Vérifie la préférence AVANT d'insérer : centralisé ici plutôt que dupliqué dans chacun des
-- appelants (030, 031, 033, 035, 038, 041, 043, 047 à ce jour) — un seul endroit à faire évoluer
-- si le modèle de préférences change plus tard.
create or replace function public.create_notification(
  p_profile uuid, p_type text, p_title text, p_body text, p_link_type text, p_link_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_enabled boolean;
begin
  select coalesce((notif_prefs ->> p_type)::boolean, true) into v_enabled
  from public.profiles where id = p_profile;

  if coalesce(v_enabled, true) then
    insert into public.notifications (profile_id, type, title, body, link_type, link_id)
    values (p_profile, p_type, p_title, p_body, p_link_type, p_link_id);
  end if;
end;
$$;

-- ============================================================
-- FICHIER: 050_notifications_purge.sql
-- ============================================================
-- Ludodex Online — 050 : purge automatique de l'historique des notifications
-- Décision utilisateur (28/09/2026) : le fil de notifications grandissait indéfiniment (voir
-- 029_notifications.sql), plus prévu de le laisser ainsi. Purge complète (lues ET non lues) de
-- tout ce qui a plus de 24h, rejouée automatiquement toutes les 24h via pg_cron (disponible sur
-- Supabase, y compris en Free tier). Le job tourne avec les privilèges du scheduler (superuser),
-- donc bypass RLS naturellement — pas besoin de policy delete supplémentaire pour le joueur.

create extension if not exists pg_cron;

create or replace function public.purge_old_notifications()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.notifications where created_at < now() - interval '24 hours';
$$;

-- cron.schedule() ne remplace pas un job existant du même nom (erreur "job already exists") :
-- on désinscrit d'abord si présent, pour que ce fichier reste rejouable sans risque.
do $$
begin
  perform cron.unschedule('purge_old_notifications_daily');
exception when others then null;
end $$;

select cron.schedule(
  'purge_old_notifications_daily',
  '0 3 * * *', -- tous les jours à 3h (heure du serveur, UTC)
  $$select public.purge_old_notifications();$$
);

-- ============================================================
-- FICHIER: 051_card_tags.sql
-- ============================================================
-- Ludodex Online — 051 : tags personnels sur une carte (fiche détail)
-- Étiquettes libres posées par le joueur sur une carte pour s'organiser (ex. "à échanger",
-- "pour le deck duel") — demandées à l'utilisateur "étiquettes" côté WikiMasters, appelées "tags"
-- ici. Pas de FK vers card_catalogue : all_cards_catalogue (048) mélange jeux et personnages sous
-- le même nom de colonne card_id mais deux tables sources différentes, une carte tag doit marcher
-- pour les deux sans distinction.

create table if not exists public.card_tags (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  card_id text not null,
  tag text not null check (char_length(tag) between 1 and 32),
  created_at timestamptz not null default now(),
  primary key (profile_id, card_id, tag)
);

create index if not exists card_tags_profile_idx on public.card_tags (profile_id, tag);

alter table public.card_tags enable row level security;

drop policy if exists "card_tags_select_own" on public.card_tags;
create policy "card_tags_select_own"
  on public.card_tags for select
  using (auth.uid() = profile_id);

drop policy if exists "card_tags_insert_own" on public.card_tags;
create policy "card_tags_insert_own"
  on public.card_tags for insert
  with check (auth.uid() = profile_id);

drop policy if exists "card_tags_delete_own" on public.card_tags;
create policy "card_tags_delete_own"
  on public.card_tags for delete
  using (auth.uid() = profile_id);

-- ============================================================
-- FICHIER: 052_character_catalogue_description.sql
-- ============================================================
-- Ludodex Online — 052 : description française par personnage (character_catalogue)
-- Même besoin que 036_card_catalogue_descriptions.sql côté jeux : jusqu'ici la bio d'un
-- personnage repliait sur species/quote (voir 048_all_cards_view.sql), pas un vrai texte dédié.
-- Rempli ensuite par un script de génération (voir schema/catalogue_import/), colonne nullable en
-- attendant — bioHTML (detail.js) et cardSubText (render.js) replient déjà sur genres/quote tant
-- qu'une ligne n'a pas encore de description_fr.

alter table public.character_catalogue add column if not exists description_fr text;

-- ============================================================
-- FICHIER: 053_all_cards_view_character_description.sql
-- ============================================================
-- Ludodex Online — 053 : la vue all_cards_catalogue expose la vraie description_fr d'un
-- personnage (052_character_catalogue_description.sql) au lieu d'un null en dur — sans ça
-- bioHTML/cardSubText retombent toujours sur species/quote même une fois les descriptions
-- générées et importées.

create or replace view public.all_cards_catalogue as
select
  card_id, 'game'::text as kind, title, platform_name, year, developer, image_url,
  rarity, rarity_name, rarity_color, family_color, atk, def,
  description_en, description_fr, genres
from public.card_catalogue
union all
select
  character_id as card_id, 'character'::text as kind, name as title, franchise as platform_name,
  null::integer as year, null::text as developer, image_url,
  rarity, rarity_name, rarity_color, family_color, atk, def,
  null::text as description_en, description_fr,
  coalesce(species, quote) as genres
from public.character_catalogue;

grant select on public.all_cards_catalogue to anon, authenticated;

-- ============================================================
-- FICHIER: 054_profile_avatar_showcase.sql
-- ============================================================
-- Ludodex Online — 054 : photo de profil + vitrine de 4 cartes
-- La "photo de profil" n'est pas un fichier uploadé (pas d'infra de stockage/modération pour ça
-- pour l'instant) : le joueur choisit une carte de SA collection, dont l'illustration sert
-- d'avatar (cohérent avec un jeu de cartes, évite d'ouvrir un système d'upload d'images libres).
-- Même logique pour la vitrine : 4 emplacements, chacun une carte de la collection.

alter table public.profiles add column if not exists avatar_card_id text;
alter table public.profiles add column if not exists avatar_shiny boolean not null default false;

-- Pas de FK vers card_catalogue : une carte de vitrine/avatar peut être un personnage
-- (character_catalogue, via all_cards_catalogue) — voir 051_card_tags.sql pour le même choix.
create table if not exists public.profile_showcase (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  slot smallint not null check (slot between 1 and 4),
  card_id text not null,
  shiny boolean not null default false,
  primary key (profile_id, slot)
);

alter table public.profile_showcase enable row level security;

-- Lecture publique : une vitrine n'a de sens que vue par d'autres joueurs (futur profil public) ;
-- ce n'est pas une donnée sensible (juste "quelles cartes ce joueur met en avant").
drop policy if exists "profile_showcase_select_all" on public.profile_showcase;
create policy "profile_showcase_select_all"
  on public.profile_showcase for select
  using (true);

drop policy if exists "profile_showcase_upsert_own" on public.profile_showcase;
create policy "profile_showcase_upsert_own"
  on public.profile_showcase for insert
  with check (auth.uid() = profile_id);

drop policy if exists "profile_showcase_update_own" on public.profile_showcase;
create policy "profile_showcase_update_own"
  on public.profile_showcase for update
  using (auth.uid() = profile_id);

drop policy if exists "profile_showcase_delete_own" on public.profile_showcase;
create policy "profile_showcase_delete_own"
  on public.profile_showcase for delete
  using (auth.uid() = profile_id);

-- ============================================================
-- FICHIER: 055_all_cards_view_security_invoker.sql
-- ============================================================
-- Ludodex Online — 055 : corrige l'alerte "Security Definer View" du linter Supabase sur
-- public.all_cards_catalogue (048/053_*.sql).
--
-- Une vue Postgres sans `security_invoker` s'exécute avec les droits de son CRÉATEUR plutôt que
-- ceux de l'utilisateur qui l'interroge — équivalent en pratique à SECURITY DEFINER pour l'accès
-- aux tables sous-jacentes. Sans risque réel ici (card_catalogue et character_catalogue sont déjà
-- en lecture publique pour anon/authenticated, aucune RLS par ligne à contourner), mais c'est la
-- bonne pratique recommandée par Supabase (Postgres 15+) : on la corrige plutôt que d'ignorer
-- l'alerte.

alter view public.all_cards_catalogue set (security_invoker = true);

-- ============================================================
-- FICHIER: 056_friends_and_message_purge.sql
-- ============================================================
-- Ludodex Online — 056 : vraie liste d'amis (remplace la démo locale de social.html) + purge
-- automatique des messages privés de plus de 30 jours.

/* ===== Amis ===== */

create table if not exists public.friends (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  constraint friends_no_self check (requester_id <> addressee_id),
  constraint friends_unique_pair unique (requester_id, addressee_id)
);

alter table public.friends enable row level security;

drop policy if exists "friends_select_participant" on public.friends;
create policy "friends_select_participant"
  on public.friends for select
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

drop policy if exists "friends_insert_as_requester" on public.friends;
create policy "friends_insert_as_requester"
  on public.friends for insert
  with check (auth.uid() = requester_id);

-- Seul le destinataire peut accepter (pending -> accepted) ; personne ne peut rétrograder une
-- amitié acceptée par update (il faut la supprimer, voir la policy delete ci-dessous).
drop policy if exists "friends_update_addressee_accept" on public.friends;
create policy "friends_update_addressee_accept"
  on public.friends for update
  using (auth.uid() = addressee_id and status = 'pending')
  with check (status = 'accepted');

-- Les deux camps peuvent supprimer la relation (annuler une demande envoyée, refuser une demande
-- reçue, ou retirer un ami existant).
drop policy if exists "friends_delete_participant" on public.friends;
create policy "friends_delete_participant"
  on public.friends for delete
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create index if not exists friends_addressee_idx on public.friends(addressee_id, status);
create index if not exists friends_requester_idx on public.friends(requester_id, status);

/* ===== Purge des messages privés ===== */
-- Même mécanisme que purge_old_notifications (050_notifications_purge.sql) : chaque message
-- privé (007_messages_and_moderation.sql) survit 30 jours après son envoi puis disparaît
-- individuellement via ce job quotidien, pour ne pas accumuler indéfiniment du stockage inutile.

create extension if not exists pg_cron;

create or replace function public.purge_old_private_messages()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.private_messages where created_at < now() - interval '30 days';
$$;

do $$
begin
  perform cron.unschedule('purge_old_private_messages_daily');
exception when others then null;
end $$;

select cron.schedule(
  'purge_old_private_messages_daily',
  '0 4 * * *', -- tous les jours à 4h (heure du serveur, UTC) — décalé de purge_old_notifications
  $$select public.purge_old_private_messages();$$
);

-- ============================================================
-- FICHIER: 057_founder_role_enum.sql
-- ============================================================
-- Ludodex Online — 057 : ajoute la valeur 'fondateur' à l'enum profile_role (001_extensions_and_enums.sql).
--
-- À EXÉCUTER SEUL, DANS SA PROPRE REQUÊTE — PAS DANS LE PASTE GROUPÉ ALL_IN_ONE.
-- Postgres n'autorise pas de manière fiable l'usage d'une valeur d'enum tout juste ajoutée par
-- ALTER TYPE ... ADD VALUE dans la même transaction (le SQL Editor de Supabase envoie tout un
-- paste comme une seule transaction implicite) : 058_profile_vip_and_rank.sql référence
-- 'fondateur' dans une policy, donc cette valeur doit déjà exister et être validée AVANT.
-- Lance ce fichier, attends qu'il termine, puis lance 058 (ou le reste de l'ALL_IN_ONE).

alter type profile_role add value if not exists 'fondateur';

-- ============================================================
-- FICHIER: 058_profile_vip_and_rank.sql
-- ============================================================
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

-- ============================================================
-- FICHIER: 059_fix_open_booster_regression.sql
-- ============================================================
-- Ludodex Online — 059 : corrige une régression introduite par 058_profile_vip_and_rank.sql.
--
-- 058 a réécrit open_booster() en repartant par erreur du corps de 010 (le tout premier jet) pour
-- y ajouter la branche VIP, au lieu de repartir de la version réellement en place (040, qui ajoute
-- le suivi des statistiques ET appelle _pick_random_card — devenu O(log n) via l'index
-- (rarity, random_key) depuis 047). Conséquence de cette régression :
--   1. Perf : retour au tirage `ORDER BY random() LIMIT 1`, le scan complet que 047 avait
--      justement éliminé (timeout Postgres sur la rareté Commune, ~78 000 lignes).
--   2. Correction : les compteurs boosters_opened_total / golds_opened_total /
--      shiny_drawn_total / pulls_rare / pulls_epic / pulls_legendary / pulls_mythic n'étaient
--      plus mis à jour — la page Profil (get_achievement_progress) aurait affiché des stats figées
--      pour toute ouverture de booster faite pendant que 058 était en place.
-- Ce fichier réapplique le corps de 040 (perf + stats) et y garde seulement l'ajout légitime de
-- 058 : régénération 1/3min plafonnée à 15 pour un compte vip, sinon 1/10min plafonnée à 10.

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
  v_state.boosters_opened_total := v_state.boosters_opened_total + 1;
  if v_gold then
    v_state.golds_opened_total := v_state.golds_opened_total + 1;
  end if;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);

    -- _pick_random_card ignore désormais son 2e paramètre (voir 047) : recherche indexée par
    -- plage sur (rarity, random_key), plus le comptage+offset de 040/041.
    v_card_id := public._pick_random_card(v_rarity, null);

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;
    if v_shiny then
      v_state.shiny_drawn_total := v_state.shiny_drawn_total + 1;
    end if;
    if v_rarity = 2 then v_state.pulls_rare := v_state.pulls_rare + 1;
    elsif v_rarity = 3 then v_state.pulls_epic := v_state.pulls_epic + 1;
    elsif v_rarity = 4 then v_state.pulls_legendary := v_state.pulls_legendary + 1;
    elsif v_rarity = 5 then v_state.pulls_mythic := v_state.pulls_mythic + 1;
    end if;

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
        boosters_opened_total = v_state.boosters_opened_total,
        golds_opened_total = v_state.golds_opened_total,
        shiny_drawn_total = v_state.shiny_drawn_total,
        pulls_rare = v_state.pulls_rare,
        pulls_epic = v_state.pulls_epic,
        pulls_legendary = v_state.pulls_legendary,
        pulls_mythic = v_state.pulls_mythic,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;

-- ============================================================
-- FICHIER: 060_rpc_rate_limiting.sql
-- ============================================================
-- Ludodex Online — 060 : rate limiting serveur sur les RPC sensibles (Tier 1 sécurité, voir la
-- mémoire auto-Claude ludodex_roadmap_priority).
--
-- Constat : open_booster()/run_duel() ont déjà un plafond fonctionnel (boosters_available régénéré
-- au fil du temps, duels_played_today <= 5) mais aucun garde-fou contre un client qui spamme l'appel
-- en boucle serrée (coût CPU/lock inutile même quand la réponse finale est un refus) ;
-- propose_trade() n'a AUCUN plafond — un compte peut spammer des propositions à une cible (séquestre
-- des cartes à chaque appel, inonde ses notifications). Ce fichier ajoute un throttle générique
-- réutilisable, appliqué aux trois RPC identifiées par la roadmap.
--
-- Table dédiée, jamais exposée au client (RLS activée sans policy = deny-all pour anon/authenticated,
-- seules les fonctions SECURITY DEFINER ci-dessous y touchent).
create table if not exists public.rpc_rate_limit (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  rpc_name text not null,
  window_start timestamptz not null,
  call_count int not null default 1,
  primary key (profile_id, rpc_name)
);
alter table public.rpc_rate_limit enable row level security;

-- Compteur à fenêtre glissante simple : (p_max_calls) appels max toutes les (p_window_seconds).
-- Lève une exception au-delà, sinon incrémente et laisse l'appelant continuer. `for update` sur la
-- ligne du compteur évite la course entre deux appels concurrents du même joueur.
create or replace function public._enforce_rate_limit(p_rpc text, p_max_calls int, p_window_seconds int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_now timestamptz := now();
  v_row public.rpc_rate_limit%rowtype;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_row from public.rpc_rate_limit
    where profile_id = v_profile and rpc_name = p_rpc for update;

  if not found then
    insert into public.rpc_rate_limit (profile_id, rpc_name, window_start, call_count)
      values (v_profile, p_rpc, v_now, 1);
    return;
  end if;

  if v_now - v_row.window_start > (p_window_seconds || ' seconds')::interval then
    update public.rpc_rate_limit set window_start = v_now, call_count = 1
      where profile_id = v_profile and rpc_name = p_rpc;
    return;
  end if;

  if v_row.call_count >= p_max_calls then
    raise exception 'Trop de tentatives, réessaie dans quelques instants.';
  end if;

  update public.rpc_rate_limit set call_count = call_count + 1
    where profile_id = v_profile and rpc_name = p_rpc;
end;
$$;

revoke execute on function public._enforce_rate_limit(text, int, int) from public, anon, authenticated;

-- open_booster() : reprend intégralement le corps de 059 (perf random_key + stats + régénération
-- vip/non-vip), ajoute juste l'appel au throttle en tout premier (30 appels / 60s — large marge au-
-- dessus de tout usage humain réel, coupe seulement le script qui boucle sans attendre la réponse).
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

  perform public._enforce_rate_limit('open_booster', 30, 60);

  select vip into v_vip from public.profiles where id = v_profile;
  v_regen_ms := case when v_vip then 3 * 60 * 1000 else 10 * 60 * 1000 end;
  v_max_packs := case when v_vip then 15 else 10 end;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

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
  v_state.boosters_opened_total := v_state.boosters_opened_total + 1;
  if v_gold then
    v_state.golds_opened_total := v_state.golds_opened_total + 1;
  end if;

  for s in 0..4 loop
    if v_gold then
      v_weights := array[0, 0, 62, 26, 9, 3];        -- W_GOLD
    elsif s = 4 then
      v_weights := array[0, 62, 25, 9, 3.3, 0.7];    -- W_LAST (5e carte)
    else
      v_weights := array[55, 25, 13, 5, 1.7, 0.3];   -- W_NORMAL
    end if;

    v_rarity := public.pick_weighted_rarity(v_weights);
    v_card_id := public._pick_random_card(v_rarity, null);

    if v_card_id is null then
      raise exception 'Catalogue de cartes vide pour la rareté %.', v_rarity;
    end if;

    v_shiny := random() < v_shiny_rate;
    if v_shiny then
      v_state.shiny_drawn_total := v_state.shiny_drawn_total + 1;
    end if;
    if v_rarity = 2 then v_state.pulls_rare := v_state.pulls_rare + 1;
    elsif v_rarity = 3 then v_state.pulls_epic := v_state.pulls_epic + 1;
    elsif v_rarity = 4 then v_state.pulls_legendary := v_state.pulls_legendary + 1;
    elsif v_rarity = 5 then v_state.pulls_mythic := v_state.pulls_mythic + 1;
    end if;

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
        boosters_opened_total = v_state.boosters_opened_total,
        golds_opened_total = v_state.golds_opened_total,
        shiny_drawn_total = v_state.shiny_drawn_total,
        pulls_rare = v_state.pulls_rare,
        pulls_epic = v_state.pulls_epic,
        pulls_legendary = v_state.pulls_legendary,
        pulls_mythic = v_state.pulls_mythic,
        updated_at = v_now
    where profile_id = v_profile;

  return jsonb_build_object(
    'gold', v_gold,
    'boosters_available', v_state.boosters_available,
    'cards', v_results
  );
end;
$$;

-- run_duel() : reprend le corps de 035 à l'identique, ajoute le throttle (10 appels / 60s — le
-- plafond de 5/jour protège déjà l'économie, ça coupe juste le spam de requêtes en boucle).
create or replace function public.run_duel(p_deck text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_card_id text;
  v_card record;
  v_opponent record;
  v_my_wins integer := 0;
  v_their_wins integer := 0;
  v_rounds jsonb := '[]'::jsonb;
  v_result text;
  v_won boolean;
  v_reward integer;
  v_duel_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  perform public._enforce_rate_limit('run_duel', 10, 60);

  if p_deck is null or array_length(p_deck, 1) <> 5 then
    raise exception 'Le deck doit contenir exactement 5 cartes.';
  end if;
  if array_length(p_deck, 1) <> (select count(distinct x) from unnest(p_deck) x) then
    raise exception 'Chaque carte du deck doit être différente.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  if v_state.duel_date is distinct from current_date then
    update public.player_state set duel_date = current_date, duels_played_today = 0
      where profile_id = v_profile;
    v_state.duels_played_today := 0;
  end if;
  if v_state.duels_played_today >= 5 then
    raise exception 'Plus de duels disponibles aujourd''hui.';
  end if;

  foreach v_card_id in array p_deck loop
    if not exists (
      select 1 from public.collection
      where profile_id = v_profile and card_id = v_card_id and count > 0
    ) then
      raise exception 'Tu ne possèdes pas la carte %.', v_card_id;
    end if;

    select card_id, title, atk, def, rarity into v_card
      from public.card_catalogue where card_id = v_card_id;

    select card_id, title, atk, def into v_opponent
      from public.card_catalogue
      where rarity = v_card.rarity and card_id <> v_card.card_id
      order by random() limit 1;
    if not found then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity
        order by random() limit 1;
    end if;

    if (v_card.atk - v_opponent.def) > (v_opponent.atk - v_card.def) then
      v_result := 'win'; v_my_wins := v_my_wins + 1;
    elsif (v_opponent.atk - v_card.def) > (v_card.atk - v_opponent.def) then
      v_result := 'lose'; v_their_wins := v_their_wins + 1;
    else
      v_result := 'draw';
    end if;

    v_rounds := v_rounds || jsonb_build_object(
      'my_card_id', v_card.card_id, 'my_title', v_card.title, 'my_atk', v_card.atk,
      'opp_card_id', v_opponent.card_id, 'opp_title', v_opponent.title, 'opp_def', v_opponent.def,
      'result', v_result
    );
  end loop;

  v_won := v_my_wins > v_their_wins;
  v_reward := case when v_won then 40 + v_my_wins * 10 else round(40 * 0.25) end;

  update public.player_state set
    coins = coins + v_reward,
    duels_played_today = duels_played_today + 1,
    duel_wins_total = duel_wins_total + (case when v_won then 1 else 0 end),
    updated_at = now()
  where profile_id = v_profile;

  insert into public.duel_history (profile_id, won, my_wins, their_wins, reward, rounds)
    values (v_profile, v_won, v_my_wins, v_their_wins, v_reward, v_rounds)
    returning id into v_duel_id;

  perform public.create_notification(
    v_profile, 'duel_result',
    case when v_won then 'Duel gagné' else 'Duel perdu' end,
    v_my_wins || ' - ' || v_their_wins || ' · +' || v_reward || ' pièces.',
    'duel', v_duel_id::text
  );

  return jsonb_build_object(
    'id', v_duel_id, 'won', v_won, 'my_wins', v_my_wins, 'their_wins', v_their_wins,
    'reward', v_reward, 'rounds', v_rounds
  );
end;
$$;

-- propose_trade() : reprend le corps de 033 à l'identique, ajoute le throttle (8 appels / 300s —
-- c'est la seule des trois RPC sans plafond fonctionnel existant, donc le vrai garde-fou ici).
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

  perform public._enforce_rate_limit('propose_trade', 8, 300);

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

-- ============================================================
-- FICHIER: 061_login_lockout.sql
-- ============================================================
-- Ludodex Online — 061 : lockout brute-force sur la connexion (Tier 1 sécurité, voir la mémoire
-- auto-Claude ludodex_roadmap_priority). Plan Supabase = Free, donc pas de pg_net/HTTP hook — pur
-- Postgres, ce que le "Password Verification Attempt" hook supporte nativement (voir doc Supabase :
-- https://supabase.com/docs/guides/auth/auth-hooks/password-verification-hook).
--
-- Politique : 8 échecs en 15 minutes glissantes → compte verrouillé 15 minutes (connexion refusée
-- même avec le bon mot de passe pendant le verrouillage). Un succès remet le compteur à zéro. Le
-- hook s'exécute côté `supabase_auth_admin` (jamais appelable par un client) et DOIT être branché
-- manuellement dans le Dashboard une fois cette migration collée — voir l'étape en bas de fichier,
-- aucune commande SQL ne peut le faire à la place.
create table if not exists public.login_lockout (
  user_id uuid primary key,
  failure_count int not null default 0,
  first_failure_at timestamptz,
  locked_until timestamptz
);
alter table public.login_lockout enable row level security;

create or replace function public.hook_password_verification_attempt(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := (event ->> 'user_id')::uuid;
  v_valid boolean := coalesce((event -> 'valid')::boolean, false);
  v_now timestamptz := now();
  v_row public.login_lockout%rowtype;
  v_window constant interval := interval '15 minutes';
  v_max_failures constant int := 8;
begin
  select * into v_row from public.login_lockout where user_id = v_user_id for update;

  if found and v_row.locked_until is not null and v_row.locked_until > v_now then
    return jsonb_build_object(
      'decision', 'reject',
      'message', 'Compte temporairement verrouillé après trop de tentatives, réessaie dans quelques minutes.'
    );
  end if;

  if v_valid then
    if found then
      update public.login_lockout
        set failure_count = 0, first_failure_at = null, locked_until = null
        where user_id = v_user_id;
    end if;
    return jsonb_build_object('decision', 'continue');
  end if;

  -- Échec : incrémente si dans la fenêtre glissante, sinon redémarre le compteur.
  if not found or v_row.first_failure_at is null or v_now - v_row.first_failure_at > v_window then
    insert into public.login_lockout (user_id, failure_count, first_failure_at, locked_until)
      values (v_user_id, 1, v_now, null)
      on conflict (user_id) do update
        set failure_count = 1, first_failure_at = v_now, locked_until = null;
    return jsonb_build_object('decision', 'continue');
  end if;

  if v_row.failure_count + 1 >= v_max_failures then
    update public.login_lockout
      set failure_count = v_row.failure_count + 1, locked_until = v_now + v_window
      where user_id = v_user_id;
    return jsonb_build_object(
      'decision', 'reject',
      'message', 'Trop de tentatives échouées, compte verrouillé 15 minutes.'
    );
  end if;

  update public.login_lockout set failure_count = v_row.failure_count + 1 where user_id = v_user_id;
  return jsonb_build_object('decision', 'continue');
end;
$$;

revoke execute on function public.hook_password_verification_attempt(jsonb) from public, anon, authenticated;
grant execute on function public.hook_password_verification_attempt(jsonb) to supabase_auth_admin;

-- ⚠️ Étape manuelle obligatoire (Dashboard Supabase, aucun équivalent SQL) :
-- Authentication → Hooks → "Password Verification Attempt" → activer → choisir la fonction
-- Postgres public.hook_password_verification_attempt. Sans ça, cette migration ne fait rien : la
-- table/fonction existent mais Supabase Auth ne les appelle pas tant que le hook n'est pas branché
-- dans les réglages.

-- ============================================================
-- FICHIER: 062_admin_hub_foundation.sql
-- ============================================================
-- Ludodex Online — 062 : fondations du hub admin/modérateur (Tier 2, voir la mémoire auto-Claude
-- ludodex_admin_interface_planned / ludodex_roadmap_priority pour le détail complet des décisions
-- prises avec Doktor le 29/09/2026). Ce fichier pose le schéma et les briques communes ; les
-- actions elles-mêmes (063) et le hub côté site sont dans les fichiers suivants.
--
-- Ce que ce fichier NE fait PAS (explicitement laissé de côté, décisions déjà actées) :
--   - Le "piège anti-IA" (commentaires trompeurs pour faire refuser une IA scannant le code) :
--     Doktor a demandé de confirmer l'intention avant de le construire, pas de le faire en
--     silence. Pas construit ici, à reposer la question le moment venu.
--   - 2FA, appareils de confiance, rotation des clés, kill-switch, verrouillage brute-force
--     général : classé Tier 3 dans la roadmap, plus gros que le hub lui-même, séquencé à part.
--     Le seul garde-fou d'accès construit ici est l'élévation par mot de passe + expiration.

-- 1) Statuts de modération visibles publiquement (badge "muet"/"suspendu" sur le profil d'un
--    joueur, décision explicite de Doktor : pas juste interne à l'équipe). `profiles_select_all`
--    (002) les rend déjà lisibles par tous ; on empêche juste le joueur de se les changer
--    lui-même en étendant le trigger anti-auto-promotion existant, comme role/vip.
alter table public.profiles add column if not exists muted boolean not null default false;
alter table public.profiles add column if not exists suspended boolean not null default false;

create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
as $$
begin
  if (new.role is distinct from old.role
      or new.vip is distinct from old.vip
      or new.muted is distinct from old.muted
      or new.suspended is distinct from old.suspended)
     and auth.uid() = old.id then
    raise exception 'Ce champ ne peut pas être modifié par le joueur lui-même.';
  end if;
  return new;
end;
$$;

-- 2) Notes internes par joueur — jamais visibles du joueur, partagées par toute l'équipe (pas de
--    silo par modérateur, décision actée). Table séparée de `profiles` exprès : `profiles` a une
--    policy de lecture publique (using (true)), impossible d'y cacher une colonne à la RLS
--    (Postgres filtre par ligne, pas par colonne) — donc une note interne DOIT vivre ailleurs.
create table if not exists public.player_notes (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  note text not null,
  created_at timestamptz not null default now()
);
create index if not exists player_notes_profile_idx on public.player_notes (profile_id, created_at desc);
alter table public.player_notes enable row level security;

drop policy if exists "player_notes_select_staff" on public.player_notes;
create policy "player_notes_select_staff"
  on public.player_notes for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('moderator','admin','fondateur')));
-- Pas de policy insert cliente : passe uniquement par add_player_note() (063), pour garder
-- author_id fiable (jamais fourni par le client) et pouvoir logger l'action si besoin plus tard.

-- 3) Journal d'audit — toute action qui change des données (jamais la simple consultation d'une
--    fiche joueur, y compris son email, décision actée). IP best-effort : PostgREST/Supabase ne
--    donne pas l'IP réelle du client à une fonction SECURITY DEFINER (inet_client_addr() renvoie
--    l'IP du pooler, pas celle du navigateur) — le client fournit la sienne (ex. via un lookup
--    public type ipify avant l'appel), donc c'est une IP déclarée par le client, pas vérifiée
--    cryptographiquement. Suffisant pour de la traçabilité/contexte d'audit, pas pour du blocage
--    de sécurité — limite à documenter dans le hub, pas à cacher.
create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  -- `on delete set null` sur les deux colonnes : la suppression définitive d'un compte (action
  -- elle-même journalisée avant coup, voir 063) ne doit jamais échouer parce qu'une ligne d'audit
  -- plus ancienne référence ce compte comme cible, ni parce qu'un compte d'équipe supprimé un jour
  -- avait des actions passées à son actif — l'historique reste, juste sans le lien FK.
  actor_id uuid references public.profiles(id) on delete set null,
  -- Pseudo capturé au moment de l'action (pas une jointure live) : reste lisible même après un
  -- `set null` FK ci-dessus si le compte est supprimé plus tard.
  actor_username text,
  action text not null,
  target_profile_id uuid references public.profiles(id) on delete set null,
  target_username text,
  reason text,
  detail jsonb not null default '{}'::jsonb,
  client_ip text,
  created_at timestamptz not null default now()
);
create index if not exists audit_log_target_idx on public.audit_log (target_profile_id, created_at desc);
create index if not exists audit_log_created_idx on public.audit_log (created_at desc);
alter table public.audit_log enable row level security;

-- Visible à toute l'équipe (pas juste admin), décision actée : transparence totale.
drop policy if exists "audit_log_select_staff" on public.audit_log;
create policy "audit_log_select_staff"
  on public.audit_log for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('moderator','admin','fondateur')));
-- Pas de policy insert cliente : uniquement via public._log_audit() (helper interne, 063),
-- jamais appelée directement par le client (revoke plus bas dans 063).

-- 4) Élévation de session du hub — être connecté avec le bon rôle ne suffit pas pour agir dans le
--    hub, il faut une reconfirmation de mot de passe (décision actée), valable 15 minutes
--    glissantes. Le mot de passe est revérifié CÔTÉ CLIENT via un second appel à
--    supabaseClient.auth.signInWithPassword (c'est Supabase Auth qui vérifie le mot de passe, pas
--    Postgres — une fonction SQL ne peut pas le faire) ; une fois ce second appel réussi, le
--    client appelle grant_hub_elevation() (063) qui pose la fenêtre d'élévation ici. Toute action
--    sensible du hub vérifie cette fenêtre via _require_elevated() (063) avant d'agir — donc même
--    un jeton d'API volé après l'expiration ne suffit plus à agir dans le hub.
create table if not exists public.hub_elevation (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  granted_at timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.hub_elevation enable row level security;
-- Aucune policy : ni le client ni PostgREST n'y touchent directement, seulement les fonctions
-- SECURITY DEFINER de 063 (comme rpc_rate_limit/login_lockout, même schéma de protection).

-- 5) Annonce globale (bannière visible de tous les joueurs) — lecture publique des annonces
--    actives, écriture uniquement via create_announcement()/deactivate_announcement() (063).
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id),
  message text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.announcements enable row level security;

drop policy if exists "announcements_select_active" on public.announcements;
create policy "announcements_select_active"
  on public.announcements for select
  using (active);

-- 6) KPI du tableau de bord — vue simple, recalculée à chaque lecture (pas de table matérialisée :
--    le volume de joueurs ne justifie pas la complexité d'un rafraîchissement planifié pour
--    l'instant). Accessible uniquement à l'équipe.
create or replace view public.admin_kpis
with (security_invoker = true) as
select
  (select count(*) from public.profiles) as total_players,
  (select coalesce(sum(coins), 0) from public.player_state) as total_coins,
  (select coalesce(sum(boosters_opened_total), 0) from public.player_state) as total_boosters_opened,
  (select count(*) from public.message_reports where status = 'pending') as pending_reports,
  (select count(*) from public.profiles where suspended) as suspended_players,
  (select count(*) from public.profiles where muted) as muted_players;

-- Une vue n'a pas sa propre RLS : security_invoker fait qu'elle est évaluée avec les droits (et
-- policies) de l'appelant sur les tables sous-jacentes. profiles/player_state sont déjà lisibles
-- par tous (policies existantes), donc cette vue serait techniquement lisible par n'importe qui —
-- on la restreint donc via une fonction wrapper plutôt qu'un accès direct à la vue (voir
-- get_admin_kpis() dans 063), et on ne grante jamais select sur la vue elle-même.
revoke all on public.admin_kpis from public, anon, authenticated;

-- ============================================================
-- FICHIER: 063_admin_hub_actions.sql
-- ============================================================
-- Ludodex Online — 063 : fonctions du hub admin/modérateur (actions + lectures). Nécessite que
-- 062_admin_hub_foundation.sql ait déjà tourné (tables/colonnes) et 060_rpc_rate_limiting.sql
-- (réutilise _enforce_rate_limit pour le lockout de grant_hub_elevation).
--
-- Répartition des droits (décidée avec Doktor, voir mémoire ludodex_admin_interface_planned) :
--   - modérateur+ (moderator/admin/fondateur) : tout voir (sauf email, jamais exposé nulle part
--     dans ce projet — profiles n'a pas de colonne email), résoudre les signalements, mute,
--     renommage forcé, notes internes, gestionnaire d'images, annonces.
--   - admin/fondateur uniquement : ajustement de pièces (+ annulation), bannissement, octroi VIP,
--     transfert de carte, suppression de compte.
-- Toute action de ce fichier — lecture ou écriture — exige une élévation de session active
-- (_require_elevated) : "être connecté avec le bon rôle ne suffit pas pour ouvrir le hub".

-- ===== Aides internes (jamais appelables directement par le client) =====

create or replace function public._staff_role()
returns public.profile_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public._require_staff()
returns void language plpgsql security definer set search_path = public as $$
begin
  if public._staff_role() not in ('moderator','admin','fondateur') then
    raise exception 'Accès réservé à l''équipe de modération.';
  end if;
end;
$$;

create or replace function public._require_admin()
returns void language plpgsql security definer set search_path = public as $$
begin
  if public._staff_role() not in ('admin','fondateur') then
    raise exception 'Action réservée aux administrateurs.';
  end if;
end;
$$;

create or replace function public._require_elevated()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_exp timestamptz;
begin
  perform public._require_staff();
  select expires_at into v_exp from public.hub_elevation where profile_id = auth.uid();
  if v_exp is null or v_exp < now() then
    raise exception 'Session du hub expirée ou jamais ouverte — reconfirme ton mot de passe.';
  end if;
end;
$$;

create or replace function public._log_audit(
  p_action text, p_target uuid, p_reason text, p_detail jsonb, p_client_ip text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor_name text;
  v_target_name text;
begin
  select username into v_actor_name from public.profiles where id = auth.uid();
  if p_target is not null then
    select username into v_target_name from public.profiles where id = p_target;
  end if;
  insert into public.audit_log
    (actor_id, actor_username, action, target_profile_id, target_username, reason, detail, client_ip)
    values (auth.uid(), v_actor_name, p_action, p_target, v_target_name, p_reason, coalesce(p_detail, '{}'::jsonb), p_client_ip);
end;
$$;

revoke execute on function public._staff_role() from public, anon, authenticated;
revoke execute on function public._require_staff() from public, anon, authenticated;
revoke execute on function public._require_admin() from public, anon, authenticated;
revoke execute on function public._require_elevated() from public, anon, authenticated;
revoke execute on function public._log_audit(text, uuid, text, jsonb, text) from public, anon, authenticated;

-- ===== Élévation de session du hub =====

-- Vérifie le mot de passe directement côté serveur (contre auth.users.encrypted_password via
-- pgcrypto, extension déjà active depuis 001) plutôt que de faire confiance à un second appel
-- client à signInWithPassword — sinon rien n'empêcherait un jeton volé d'appeler cette fonction
-- sans jamais fournir le mot de passe. Throttlée via la même infra que 060 (5 essais / 5 min) :
-- c'est un vrai verrouillage anti brute-force propre au hub, entièrement en Postgres, donc
-- possible même sur le plan Free (contrairement au hook Auth Password Verification, réservé
-- Team/Enterprise — voir la mémoire roadmap pour ce constat).
create or replace function public.grant_hub_elevation(p_password text)
returns timestamptz
language plpgsql security definer set search_path = public, auth, extensions as $$
declare
  v_profile uuid := auth.uid();
  v_hash text;
  v_expires timestamptz;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  perform public._require_staff();
  perform public._enforce_rate_limit('grant_hub_elevation', 5, 300);

  select encrypted_password into v_hash from auth.users where id = v_profile;
  if v_hash is null or v_hash <> crypt(p_password, v_hash) then
    raise exception 'Mot de passe incorrect.';
  end if;

  v_expires := now() + interval '15 minutes';
  insert into public.hub_elevation (profile_id, granted_at, expires_at)
    values (v_profile, now(), v_expires)
    on conflict (profile_id) do update set granted_at = now(), expires_at = v_expires;
  return v_expires;
end;
$$;

revoke execute on function public.grant_hub_elevation(text) from public, anon;
grant execute on function public.grant_hub_elevation(text) to authenticated;

-- ===== Tableau de bord =====

create or replace function public.get_admin_kpis()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.admin_kpis%rowtype;
begin
  perform public._require_elevated();
  select * into v_row from public.admin_kpis;
  return to_jsonb(v_row);
end;
$$;

revoke execute on function public.get_admin_kpis() from public, anon;
grant execute on function public.get_admin_kpis() to authenticated;

-- ===== Joueurs : liste + fiche =====

create or replace function public.list_players(
  p_search text default null, p_sort text default 'created_desc', p_limit int default 50, p_offset int default 0
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_order text;
  v_limit int;
  v_result jsonb;
begin
  perform public._require_elevated();
  v_limit := least(coalesce(p_limit, 50), 200);

  v_order := case p_sort
    when 'coins_desc' then 'coins desc nulls last'
    when 'cards_desc' then 'card_count desc'
    when 'username_asc' then 'p.username asc'
    when 'role_desc' then 'p.role desc'
    else 'p.created_at desc'
  end;

  execute format(
    'select coalesce(jsonb_agg(row_to_json(t)), ''[]''::jsonb) from (
       select p.id as profile_id, p.username, p.role, p.vip, p.muted, p.suspended, p.created_at,
              ps.coins, ps.boosters_available,
              (select count(*) from public.collection c where c.profile_id = p.id) as card_count
       from public.profiles p
       left join public.player_state ps on ps.profile_id = p.id
       where ($1 is null or p.username ilike ''%%'' || $1 || ''%%'')
       order by %s
       limit $2 offset $3
     ) t', v_order
  ) into v_result using p_search, v_limit, p_offset;

  return v_result;
end;
$$;

revoke execute on function public.list_players(text, text, int, int) from public, anon;
grant execute on function public.list_players(text, text, int, int) to authenticated;

-- ===== Fiche joueur détaillée =====

create or replace function public.get_player_card(p_target uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_result jsonb;
  v_last_login timestamptz;
begin
  perform public._require_elevated();

  select last_sign_in_at into v_last_login from auth.users where id = p_target;

  select jsonb_build_object(
    'profile', (
      select (to_jsonb(p) - 'id') || jsonb_build_object('profile_id', p.id)
      from public.profiles p where p.id = p_target
    ),
    'coins', (select coins from public.player_state where profile_id = p_target),
    'boosters_available', (select boosters_available from public.player_state where profile_id = p_target),
    'last_login', v_last_login,
    'card_count_total', (select coalesce(sum(count), 0) from public.collection where profile_id = p_target),
    'card_count_distinct', (select count(*) from public.collection where profile_id = p_target),
    'recent_trades', (
      select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) from (
        select id, from_profile, to_profile, status, created_at, resolved_at
        from public.trade_offers
        where from_profile = p_target or to_profile = p_target
        order by created_at desc limit 10
      ) t
    ),
    'recent_duels', (
      select coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
        select id, won, my_wins, their_wins, reward, created_at
        from public.duel_history where profile_id = p_target
        order by created_at desc limit 10
      ) d
    ),
    'notes', (
      select coalesce(jsonb_agg(row_to_json(n)), '[]'::jsonb) from (
        select pn.id, pn.note, pn.created_at, au.username as author_username
        from public.player_notes pn
        left join public.profiles au on au.id = pn.author_id
        where pn.profile_id = p_target
        order by pn.created_at desc
      ) n
    ),
    'audit_history', (
      select coalesce(jsonb_agg(row_to_json(a)), '[]'::jsonb) from (
        select id, action, actor_username, reason, detail, created_at
        from public.audit_log where target_profile_id = p_target
        order by created_at desc limit 30
      ) a
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function public.get_player_card(uuid) from public, anon;
grant execute on function public.get_player_card(uuid) to authenticated;

-- "Recherche par carte" : qui possède telle carte et en quelle quantité (repère les exploits de
-- duplication).
create or replace function public.search_card_owners(p_card_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  perform public._require_elevated();
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select p.id as profile_id, p.username, c.shiny, c.count, c.obtained_at
    from public.collection c
    join public.profiles p on p.id = c.profile_id
    where c.card_id = p_card_id
    order by c.count desc
  ) t;
  return v_result;
end;
$$;

revoke execute on function public.search_card_owners(text) from public, anon;
grant execute on function public.search_card_owners(text) to authenticated;

-- ===== Notes internes =====

create or replace function public.add_player_note(p_target uuid, p_note text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  if p_note is null or length(trim(p_note)) = 0 then
    raise exception 'Note vide.';
  end if;
  insert into public.player_notes (profile_id, author_id, note) values (p_target, auth.uid(), p_note);
  perform public._log_audit('add_note', p_target, null, jsonb_build_object('note', p_note), null);
end;
$$;

revoke execute on function public.add_player_note(uuid, text) from public, anon;
grant execute on function public.add_player_note(uuid, text) to authenticated;

-- ===== Actions modérateur+ (mute, renommage forcé, résolution de signalement, images, annonces) =====

create or replace function public.set_player_muted(p_target uuid, p_muted boolean, p_reason text, p_client_ip text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;
  update public.profiles set muted = p_muted where id = p_target;
  perform public._log_audit(case when p_muted then 'mute' else 'unmute' end, p_target, p_reason, '{}'::jsonb, p_client_ip);
end;
$$;

revoke execute on function public.set_player_muted(uuid, boolean, text, text) from public, anon;
grant execute on function public.set_player_muted(uuid, boolean, text, text) to authenticated;

create or replace function public.force_rename_player(p_target uuid, p_new_username text, p_reason text, p_client_ip text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  perform public._require_elevated();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;
  if p_new_username is null or length(trim(p_new_username)) < 3 then
    raise exception 'Le nouveau pseudo doit faire au moins 3 caractères.';
  end if;
  select username into v_old from public.profiles where id = p_target;
  update public.profiles set username = p_new_username where id = p_target;
  perform public._log_audit('force_rename', p_target, p_reason, jsonb_build_object('old_username', v_old, 'new_username', p_new_username), p_client_ip);
exception
  when unique_violation then
    raise exception 'Ce pseudo est déjà pris.';
end;
$$;

revoke execute on function public.force_rename_player(uuid, text, text, text) from public, anon;
grant execute on function public.force_rename_player(uuid, text, text, text) to authenticated;

create or replace function public.resolve_report(p_report_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  update public.message_reports set status = 'reviewed', reviewed_by = auth.uid() where id = p_report_id;
  perform public._log_audit('resolve_report', null, p_reason, jsonb_build_object('report_id', p_report_id), null);
end;
$$;

revoke execute on function public.resolve_report(uuid, text) from public, anon;
grant execute on function public.resolve_report(uuid, text) to authenticated;

create or replace function public.list_reports(p_status text default 'pending')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  perform public._require_elevated();
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select r.id, r.reason, r.status, r.created_at,
           reporter.username as reporter_username,
           m.content as message_content, m.created_at as message_created_at,
           sender.username as sender_username, sender.id as sender_id
    from public.message_reports r
    join public.profiles reporter on reporter.id = r.reporter_id
    join public.private_messages m on m.id = r.message_id
    join public.profiles sender on sender.id = m.sender_id
    where p_status is null or r.status = p_status
    order by r.created_at desc
    limit 100
  ) t;
  return v_result;
end;
$$;

revoke execute on function public.list_reports(text) from public, anon;
grant execute on function public.list_reports(text) to authenticated;

create or replace function public.replace_card_image(p_card_id text, p_new_url text, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  perform public._require_elevated();
  if p_new_url is null or length(trim(p_new_url)) = 0 then
    raise exception 'URL vide.';
  end if;
  select image_url into v_old from public.card_catalogue where card_id = p_card_id;
  update public.card_catalogue set image_url = p_new_url, updated_at = now() where card_id = p_card_id;
  if not found then
    raise exception 'Carte introuvable : %', p_card_id;
  end if;
  perform public._log_audit('replace_card_image', null, p_reason, jsonb_build_object('card_id', p_card_id, 'old_url', v_old, 'new_url', p_new_url), null);
end;
$$;

revoke execute on function public.replace_card_image(text, text, text) from public, anon;
grant execute on function public.replace_card_image(text, text, text) to authenticated;

create or replace function public.create_announcement(p_message text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public._require_elevated();
  if p_message is null or length(trim(p_message)) = 0 then
    raise exception 'Message vide.';
  end if;
  insert into public.announcements (author_id, message) values (auth.uid(), p_message) returning id into v_id;
  perform public._log_audit('create_announcement', null, null, jsonb_build_object('announcement_id', v_id, 'message', p_message), null);
  return v_id;
end;
$$;

revoke execute on function public.create_announcement(text) from public, anon;
grant execute on function public.create_announcement(text) to authenticated;

create or replace function public.deactivate_announcement(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  update public.announcements set active = false where id = p_id;
  perform public._log_audit('deactivate_announcement', null, null, jsonb_build_object('announcement_id', p_id), null);
end;
$$;

revoke execute on function public.deactivate_announcement(uuid) from public, anon;
grant execute on function public.deactivate_announcement(uuid) to authenticated;

-- ===== Actions admin/fondateur uniquement (argent, comptes) =====

-- Plafond par ajustement unique : au-delà, ça doit remonter au fondateur directement (décision
-- actée, "exact number TBD" — 50 000 choisi comme valeur de départ raisonnable face à une
-- économie où un booster/duel rapporte des dizaines à centaines de pièces ; ajustable si besoin,
-- c'est juste une constante ici).
create or replace function public.adjust_player_coins(p_target uuid, p_delta int, p_reason text, p_client_ip text default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_cap constant int := 50000;
  v_before int;
  v_after int;
begin
  perform public._require_elevated();
  perform public._require_admin();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;
  if p_delta = 0 or abs(p_delta) > v_cap then
    raise exception 'Ajustement invalide (max ±% par action).', v_cap;
  end if;

  select coins into v_before from public.player_state where profile_id = p_target for update;
  if v_before is null then
    raise exception 'Joueur introuvable.';
  end if;
  v_after := greatest(0, v_before + p_delta);

  update public.player_state set coins = v_after, updated_at = now() where profile_id = p_target;
  perform public._log_audit('adjust_coins', p_target, p_reason,
    jsonb_build_object('delta', p_delta, 'before', v_before, 'after', v_after), p_client_ip);
  return v_after;
end;
$$;

revoke execute on function public.adjust_player_coins(uuid, int, text, text) from public, anon;
grant execute on function public.adjust_player_coins(uuid, int, text, text) to authenticated;

-- Annulation en un clic d'un ajustement passé — reproduit l'effet inverse et logge sa propre
-- entrée d'audit distincte (décision actée : pas juste "refaire l'action manuellement").
create or replace function public.undo_coin_adjustment(p_audit_id uuid, p_reason text default 'Annulation')
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_entry public.audit_log%rowtype;
  v_delta int;
  v_after int;
begin
  perform public._require_elevated();
  perform public._require_admin();

  select * into v_entry from public.audit_log where id = p_audit_id and action = 'adjust_coins';
  if not found then
    raise exception 'Entrée d''audit introuvable ou non annulable.';
  end if;
  v_delta := -1 * (v_entry.detail ->> 'delta')::int;

  update public.player_state set coins = greatest(0, coins + v_delta), updated_at = now()
    where profile_id = v_entry.target_profile_id
    returning coins into v_after;

  perform public._log_audit('undo_adjust_coins', v_entry.target_profile_id, p_reason,
    jsonb_build_object('original_audit_id', p_audit_id, 'delta', v_delta, 'after', v_after), null);
  return v_after;
end;
$$;

revoke execute on function public.undo_coin_adjustment(uuid, text) from public, anon;
grant execute on function public.undo_coin_adjustment(uuid, text) to authenticated;

create or replace function public.set_player_suspended(p_target uuid, p_suspended boolean, p_reason text, p_client_ip text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  perform public._require_admin();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;
  update public.profiles set suspended = p_suspended where id = p_target;
  perform public._log_audit(case when p_suspended then 'suspend' else 'unsuspend' end, p_target, p_reason, '{}'::jsonb, p_client_ip);
end;
$$;

revoke execute on function public.set_player_suspended(uuid, boolean, text, text) from public, anon;
grant execute on function public.set_player_suspended(uuid, boolean, text, text) to authenticated;

create or replace function public.grant_player_vip(p_target uuid, p_vip boolean, p_reason text, p_client_ip text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  perform public._require_admin();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;
  update public.profiles set vip = p_vip where id = p_target;
  perform public._log_audit(case when p_vip then 'grant_vip' else 'revoke_vip' end, p_target, p_reason, '{}'::jsonb, p_client_ip);
end;
$$;

revoke execute on function public.grant_player_vip(uuid, boolean, text, text) from public, anon;
grant execute on function public.grant_player_vip(uuid, boolean, text, text) to authenticated;

-- Transfert manuel d'une carte entre deux comptes (ex. corriger un échange buggé) — réutilise les
-- mêmes helpers internes que les échanges joueurs (033_rpc_trades.sql), déjà pensés pour
-- séquestrer/rendre proprement des cartes.
create or replace function public.transfer_card(
  p_from uuid, p_to uuid, p_card_id text, p_shiny boolean, p_count int, p_reason text, p_client_ip text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_items jsonb;
begin
  perform public._require_elevated();
  perform public._require_admin();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;
  if coalesce(p_count, 0) < 1 then
    raise exception 'Quantité invalide.';
  end if;

  v_items := jsonb_build_array(jsonb_build_object('card_id', p_card_id, 'shiny', coalesce(p_shiny, false), 'count', p_count));
  perform public._trade_take_cards(p_from, v_items);
  perform public._trade_give_cards(p_to, v_items);

  perform public._log_audit('transfer_card', p_to, p_reason,
    jsonb_build_object('from', p_from, 'card_id', p_card_id, 'shiny', coalesce(p_shiny, false), 'count', p_count), p_client_ip);
end;
$$;

revoke execute on function public.transfer_card(uuid, uuid, text, boolean, int, text, text) from public, anon;
grant execute on function public.transfer_card(uuid, uuid, text, boolean, int, text, text) to authenticated;

-- Suppression définitive — la plus sensible : reconfirmation dans l'UI (taper le pseudo exact)
-- ET revérifiée ici côté serveur (p_confirm_username doit correspondre), pas seulement côté
-- client. L'audit est écrit AVANT le delete (sinon target_profile_id serait déjà passé à null par
-- le `on delete set null` de 062 avant même l'insert).
create or replace function public.delete_player_account(p_target uuid, p_reason text, p_confirm_username text, p_client_ip text default null)
returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_username text;
begin
  perform public._require_elevated();
  perform public._require_admin();
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Un motif est obligatoire.';
  end if;

  select username into v_username from public.profiles where id = p_target;
  if v_username is null then
    raise exception 'Joueur introuvable.';
  end if;
  if p_confirm_username is null or p_confirm_username <> v_username then
    raise exception 'Confirmation invalide : le pseudo saisi ne correspond pas.';
  end if;

  perform public._log_audit('delete_account', p_target, p_reason, jsonb_build_object('username', v_username), p_client_ip);
  delete from auth.users where id = p_target;
end;
$$;

revoke execute on function public.delete_player_account(uuid, text, text, text) from public, anon;
grant execute on function public.delete_player_account(uuid, text, text, text) to authenticated;

-- ===== Alerte temps réel à l'équipe sur un nouveau signalement =====
-- Réutilise le système de notifications existant (cloche, js/notifications.js) plutôt qu'un canal
-- séparé, décision actée. Notifie tous les comptes modérateur/admin/fondateur.
create or replace function public.notify_staff_new_report()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_staff record;
begin
  for v_staff in select id from public.profiles where role in ('moderator','admin','fondateur') loop
    perform public.create_notification(
      v_staff.id, 'new_report', 'Nouveau signalement',
      'Un message vient d''être signalé, à traiter dans le hub.',
      'report', new.id::text
    );
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_staff_new_report on public.message_reports;
create trigger trg_notify_staff_new_report
  after insert on public.message_reports
  for each row execute function public.notify_staff_new_report();


-- ============================================================
-- FICHIER: 064_admin_image_review_queue.sql
-- ============================================================
-- Ludodex Online — 064 : file de triage des images du catalogue (retour Doktor 29/09/2026 : le
-- gestionnaire d'images de 063, recherche par card_id exact, était "vide et incomplet" — il
-- voulait une vraie file à parcourir carte par carte avec deux choix : "Fait" (validé
-- définitivement, ne revient plus sauf si quelqu'un change la DA plus tard) et "Passer" (revient
-- plus tard, tiré au hasard parmi les cartes non encore validées).

create table if not exists public.card_image_review (
  card_id text primary key references public.card_catalogue(card_id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'done', 'skipped')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz
);
alter table public.card_image_review enable row level security;
-- Aucune policy cliente directe : uniquement via les fonctions ci-dessous (staff + élévation).

-- Tire une carte au hasard parmi celles jamais marquées "done" (donc "pending" jamais vues ET
-- "skipped" déjà passées reviennent toutes les deux dans le tirage, mélangées) — c'est le "revient
-- plus tard de manière aléatoire" demandé. Exclut définitivement les "done".
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();
  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.image_url,
           coalesce(r.status, 'pending') as review_status
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by random()
    limit 1
  ) t;
  return v_row;
end;
$$;

revoke execute on function public.get_next_image_review_card() from public, anon;
grant execute on function public.get_next_image_review_card() to authenticated;

-- p_status : 'done' (validation définitive) ou 'skipped' (revient plus tard). Repasser une carte
-- "done" en file (changement de DA) se fait juste en rappelant cette fonction avec 'skipped' ou
-- 'pending' sur ce card_id — pas besoin d'une fonction séparée, un modo/admin peut le refaire
-- depuis la recherche directe (image déjà existante par card_id, gardée en plus de la file).
create or replace function public.set_image_review_status(p_card_id text, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  if p_status not in ('done', 'skipped', 'pending') then
    raise exception 'Statut invalide.';
  end if;
  insert into public.card_image_review (card_id, status, reviewed_by, reviewed_at)
    values (p_card_id, p_status, auth.uid(), now())
    on conflict (card_id) do update set status = p_status, reviewed_by = auth.uid(), reviewed_at = now();
end;
$$;

revoke execute on function public.set_image_review_status(text, text) from public, anon;
grant execute on function public.set_image_review_status(text, text) to authenticated;

-- Compteur pour l'en-tête de l'onglet Images (combien de cartes restent à trier).
create or replace function public.count_pending_image_reviews()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public._require_elevated();
  select count(*) into v_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done';
  return v_count;
end;
$$;

revoke execute on function public.count_pending_image_reviews() from public, anon;
grant execute on function public.count_pending_image_reviews() to authenticated;

-- ============================================================
-- FICHIER: 065_card_image_requests.sql
-- ============================================================
-- Ludodex Online — 065 : demandes joueur de correction d'image + priorisation de la file de
-- triage (retour Doktor 29/09/2026) : sur la fiche détail d'une carte, un joueur peut signaler
-- que l'image lui semble cassée ; ça remonte en tête de la file de triage du hub (062-064) avec un
-- compteur visible.

create table if not exists public.card_image_requests (
  id uuid primary key default gen_random_uuid(),
  card_id text not null references public.card_catalogue(card_id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  comment text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists card_image_requests_open_idx on public.card_image_requests (card_id) where not resolved;
alter table public.card_image_requests enable row level security;

-- Un joueur voit ses propres demandes (pas celles des autres) ; l'équipe voit tout (pour le hub).
drop policy if exists "card_image_requests_select_own_or_staff" on public.card_image_requests;
create policy "card_image_requests_select_own_or_staff"
  on public.card_image_requests for select
  using (
    auth.uid() = reporter_id
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('moderator','admin','fondateur'))
  );
-- Pas de policy insert cliente directe : passe par report_card_image() ci-dessous (throttle +
-- vérifie que la carte existe).

-- Signalement joueur, n'importe quel compte connecté (pas réservé à l'équipe) — throttlé pour
-- éviter le spam (10/jour, réutilise _enforce_rate_limit de 060).
create or replace function public.report_card_image(p_card_id text, p_comment text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Authentification requise.';
  end if;
  perform public._enforce_rate_limit('report_card_image', 10, 86400);
  if not exists (select 1 from public.card_catalogue where card_id = p_card_id) then
    raise exception 'Carte introuvable.';
  end if;
  insert into public.card_image_requests (card_id, reporter_id, comment) values (p_card_id, auth.uid(), p_comment);
  -- Remet la carte en file de triage même si elle avait été marquée "done" (068/064) : un joueur
  -- qui signale un problème doit toujours faire réapparaître la carte, l'avis d'un modo passé ne
  -- doit pas masquer un vrai signalement récent.
  insert into public.card_image_review (card_id, status)
    values (p_card_id, 'pending')
    on conflict (card_id) do update set status = 'pending' where public.card_image_review.status = 'done';
end;
$$;

revoke execute on function public.report_card_image(text, text) from public, anon;
grant execute on function public.report_card_image(text, text) to authenticated;

-- File de triage priorisée : une carte avec au moins une demande non résolue passe devant tout le
-- reste (la plus signalée/la plus ancienne d'abord), sinon on retombe sur le tirage aléatoire
-- existant (064) parmi ce qui n'est pas "done".
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.image_url,
           coalesce(r.status, 'pending') as review_status,
           count(req.id) as request_count
    from public.card_image_requests req
    join public.card_catalogue c on c.card_id = req.card_id
    left join public.card_image_review r on r.card_id = c.card_id
    where not req.resolved
    group by c.card_id, c.title, c.platform_name, c.image_url, r.status
    order by count(req.id) desc, min(req.created_at) asc
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.image_url,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by random()
    limit 1
  ) t;
  return v_row;
end;
$$;

-- set_image_review_status (064) : résout aussi les demandes ouvertes quand on marque "done".
create or replace function public.set_image_review_status(p_card_id text, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_elevated();
  if p_status not in ('done', 'skipped', 'pending') then
    raise exception 'Statut invalide.';
  end if;
  insert into public.card_image_review (card_id, status, reviewed_by, reviewed_at)
    values (p_card_id, p_status, auth.uid(), now())
    on conflict (card_id) do update set status = p_status, reviewed_by = auth.uid(), reviewed_at = now();
  if p_status = 'done' then
    update public.card_image_requests set resolved = true where card_id = p_card_id and not resolved;
  end if;
end;
$$;

-- Badge du hub : nombre de cartes distinctes avec au moins une demande ouverte.
create or replace function public.count_open_image_requests()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public._require_elevated();
  select count(distinct card_id) into v_count from public.card_image_requests where not resolved;
  return v_count;
end;
$$;

revoke execute on function public.count_open_image_requests() from public, anon;
grant execute on function public.count_open_image_requests() to authenticated;

-- ============================================================
-- FICHIER: 066_admin_catalogue_editor.sql
-- ============================================================
-- Ludodex Online — 066 : éditeur de catalogue complet dans le hub (retour Doktor 29/09/2026,
-- deuxième vague) : la simple recherche par card_id ne suffisait pas — il veut parcourir le
-- catalogue comme la page "Collection" (grille de vraies cartes rendues, cardHTML()), choisir une
-- carte manuellement, et dans un gros panneau d'édition ajuster : l'URL d'image (aperçu en direct),
-- le cadrage de l'image (position via flèches directionnelles, zoom +/-), la rareté, l'ATK et le DEF.
--
-- Le cadrage (position/zoom) doit affecter le RENDU RÉEL de la carte partout sur le site (pas
-- juste un aperçu dans le hub) : nouvelles colonnes lues par cardHTML() (web/js/render.js) comme
-- n'importe quel autre champ de card_catalogue. Défauts = valeurs actuellement codées en dur dans
-- card.css (object-position:50% 35%, pas de zoom) : aucune carte existante ne change de rendu tant
-- qu'un modo/admin ne l'édite pas explicitement.
alter table public.card_catalogue add column if not exists image_pos_x smallint not null default 50 check (image_pos_x between 0 and 100);
alter table public.card_catalogue add column if not exists image_pos_y smallint not null default 35 check (image_pos_y between 0 and 100);
alter table public.card_catalogue add column if not exists image_scale numeric(4,2) not null default 1.00 check (image_scale between 1.00 and 3.00);

-- Parcours façon Collection/Toutes les cartes : recherche par titre, pagination, vraies cartes
-- rendues côté client via cardHTML() (toutes les colonnes qu'il consomme sont renvoyées ici).
create or replace function public.browse_catalogue_cards(p_search text default null, p_limit int default 60, p_offset int default 0)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_limit int; v_result jsonb;
begin
  perform public._require_elevated();
  v_limit := least(coalesce(p_limit, 60), 120);
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select card_id, title, platform_name, year, developer, image_url, atk, def,
           rarity, rarity_name, rarity_color, family_color,
           image_pos_x, image_pos_y, image_scale
    from public.card_catalogue
    where p_search is null or p_search = '' or title ilike '%' || p_search || '%'
    order by title asc
    limit v_limit offset p_offset
  ) t;
  return v_result;
end;
$$;

revoke execute on function public.browse_catalogue_cards(text, int, int) from public, anon;
grant execute on function public.browse_catalogue_cards(text, int, int) to authenticated;

create or replace function public.get_catalogue_card(p_card_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();
  select to_jsonb(t) into v_row from (
    select card_id, title, platform_name, year, developer, image_url, atk, def,
           rarity, rarity_name, rarity_color, family_color,
           image_pos_x, image_pos_y, image_scale
    from public.card_catalogue where card_id = p_card_id
  ) t;
  return v_row;
end;
$$;

revoke execute on function public.get_catalogue_card(text) from public, anon;
grant execute on function public.get_catalogue_card(text) to authenticated;

-- Édition complète d'une fiche catalogue — remplace replace_card_image (063) comme outil
-- principal du hub (gardé pour compat, plus utilisé par l'UI). Un seul approbateur (staff+,
-- décision actée pour l'image ; étendue ici à rareté/ATK/DEF puisque c'est le même écran).
-- Chaque paramètre nullable = "ne pas toucher à ce champ" (permet un enregistrement partiel).
create or replace function public.update_card_catalogue_entry(
  p_card_id text,
  p_image_url text default null,
  p_rarity smallint default null,
  p_atk int default null,
  p_def int default null,
  p_image_pos_x smallint default null,
  p_image_pos_y smallint default null,
  p_image_scale numeric default null,
  p_reason text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_old public.card_catalogue%rowtype;
  v_name text;
  v_color text;
begin
  perform public._require_elevated();

  select * into v_old from public.card_catalogue where card_id = p_card_id;
  if not found then
    raise exception 'Carte introuvable : %', p_card_id;
  end if;

  if p_rarity is not null then
    if p_rarity not between 0 and 5 then
      raise exception 'Rareté invalide (0 à 5).';
    end if;
    select name, color into v_name, v_color from (values
      (0::smallint, 'Commune', '#7d879c'),
      (1::smallint, 'Peu commune', '#2f9e68'),
      (2::smallint, 'Rare', '#2f74d0'),
      (3::smallint, 'Épique', '#8a45d6'),
      (4::smallint, 'Légendaire', '#d99a14'),
      (5::smallint, 'Mythique', '#e0457b')
    ) as r(rarity, name, color) where r.rarity = p_rarity;
  end if;

  update public.card_catalogue set
    image_url = coalesce(p_image_url, image_url),
    rarity = coalesce(p_rarity, rarity),
    rarity_name = coalesce(v_name, rarity_name),
    rarity_color = coalesce(v_color, rarity_color),
    atk = coalesce(p_atk, atk),
    def = coalesce(p_def, def),
    image_pos_x = coalesce(p_image_pos_x, image_pos_x),
    image_pos_y = coalesce(p_image_pos_y, image_pos_y),
    image_scale = coalesce(p_image_scale, image_scale),
    updated_at = now()
  where card_id = p_card_id;

  perform public._log_audit('edit_catalogue_card', null, p_reason, jsonb_build_object(
    'card_id', p_card_id,
    'image_url_before', v_old.image_url, 'image_url_after', p_image_url,
    'rarity_before', v_old.rarity, 'rarity_after', p_rarity,
    'atk_before', v_old.atk, 'atk_after', p_atk,
    'def_before', v_old.def, 'def_after', p_def,
    'image_pos_before', jsonb_build_object('x', v_old.image_pos_x, 'y', v_old.image_pos_y, 'scale', v_old.image_scale),
    'image_pos_after', jsonb_build_object('x', p_image_pos_x, 'y', p_image_pos_y, 'scale', p_image_scale)
  ), null);
end;
$$;

revoke execute on function public.update_card_catalogue_entry(text, text, smallint, int, int, smallint, smallint, numeric, text) from public, anon;
grant execute on function public.update_card_catalogue_entry(text, text, smallint, int, int, smallint, smallint, numeric, text) to authenticated;

-- get_next_image_review_card (064/065) : ajoute les champs nécessaires au vrai rendu cardHTML()
-- dans la file de triage (rareté/couleurs/ATK/DEF/cadrage), pas juste titre+image comme avant.
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row jsonb;
begin
  perform public._require_elevated();

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           count(req.id) as request_count
    from public.card_image_requests req
    join public.card_catalogue c on c.card_id = req.card_id
    left join public.card_image_review r on r.card_id = c.card_id
    where not req.resolved
    group by c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url, c.atk, c.def,
             c.rarity, c.rarity_name, c.rarity_color, c.family_color,
             c.image_pos_x, c.image_pos_y, c.image_scale, r.status
    order by count(req.id) desc, min(req.created_at) asc
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by random()
    limit 1
  ) t;
  return v_row;
end;
$$;

-- ============================================================
-- FICHIER: 067_catalogue_editor_zoom_range.sql
-- ============================================================
-- Ludodex Online — 067 : permet de dézoomer sous 1× dans l'éditeur de catalogue (retour Doktor
-- 29/09/2026 : "on peut pas dézoomer moins ?") — la contrainte de 066 plafonnait le zoom entre
-- 1.00 et 3.00, empêchant de rétrécir une image trop zoomée à la source. Nouvelle plage : 0.50 à
-- 3.00. Le défaut (1.00, rendu identique à avant 066) ne change pas.
alter table public.card_catalogue drop constraint if exists card_catalogue_image_scale_check;
alter table public.card_catalogue add constraint card_catalogue_image_scale_check check (image_scale between 0.50 and 3.00);

-- ============================================================
-- FICHIER: 068_fix_list_reports_status_cast.sql
-- ============================================================
-- Ludodex Online — 068 : corrige list_reports() (063_admin_hub_actions.sql), qui comparait
-- directement le paramètre p_status (text) à message_reports.status (enum report_status) — Postgres
-- n'a pas d'opérateur "=" entre report_status et text sans cast explicite, d'où l'erreur "operator
-- does not exist: report_status = text" constatée par Doktor dès qu'on ouvre l'onglet Signalements.
create or replace function public.list_reports(p_status text default 'pending')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  perform public._require_elevated();
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select r.id, r.reason, r.status, r.created_at,
           reporter.username as reporter_username,
           m.content as message_content, m.created_at as message_created_at,
           sender.username as sender_username, sender.id as sender_id
    from public.message_reports r
    join public.profiles reporter on reporter.id = r.reporter_id
    join public.private_messages m on m.id = r.message_id
    join public.profiles sender on sender.id = m.sender_id
    where p_status is null or r.status = p_status::report_status
    order by r.created_at desc
    limit 100
  ) t;
  return v_result;
end;
$$;

-- ============================================================
-- FICHIER: 069_platform_card_totals.sql
-- ============================================================
-- Ludodex Online — 069 : vue de comptage par plateforme, pour l'album de la Collection.
--
-- Bug réel trouvé (Doktor : "Switch je suis à 38/32 alors que je ne les ai pas toutes") :
-- `loadAlbumShelf()` (web/js/collection.js) faisait `select("platform_name, family_color")` sur
-- TOUT `card_catalogue` (239 000+ lignes) sans pagination pour compter les totaux par plateforme
-- côté client. PostgREST plafonne une réponse à 1000 lignes par défaut (`max-rows`) — le total
-- affiché n'était donc calculé que sur les 1000 premières lignes de la table, pas sur l'ensemble :
-- Switch a réellement 17 813 cartes, pas 32. "Possédées" (owned), lui, était juste (confirmé par
-- requête directe), donc owned pouvait dépasser ce faux total tronqué.
--
-- Fix : un vrai comptage GROUP BY côté serveur (une seule ligne par plateforme en retour, ~40
-- lignes au lieu de 239 000) au lieu de tout rapatrier pour compter en JS.
create or replace view public.platform_card_totals
with (security_invoker = true) as
select platform_name, min(family_color) as family_color, count(*) as total
from public.card_catalogue
group by platform_name;

-- Lecture publique, comme card_catalogue lui-même (card_catalogue_select_all, 015) : c'est un pur
-- agrégat de données déjà publiques, utilisé par la Collection de tous les joueurs.
grant select on public.platform_card_totals to anon, authenticated;

-- ============================================================
-- FICHIER: 070_browse_platform_cards.sql
-- ============================================================
-- Ludodex Online — 070 : parcours d'une plateforme dans l'album de la Collection, avec cartes
-- possédées en premier (triées par rareté) et filtre de rareté — demandé par Doktor. Fait tout le
-- tri/filtre côté serveur (une plateforme peut avoir des dizaines de milliers de cartes, comme
-- Switch avec 17 813 — impossible de trier "possédées d'abord" correctement en ne rapatriant
-- qu'une page à la fois sans ça, voir 069_platform_card_totals.sql pour le même type de problème).
--
-- SECURITY INVOKER (pas DEFINER) : pas besoin de bypasser la RLS, `collection` autorise déjà sa
-- propre lecture (collection_select_own_or_public, 004) et card_catalogue est public — cette
-- fonction n'a besoin d'aucun privilège élevé, juste d'agréger proprement.
create or replace function public.browse_platform_cards(
  p_platform text,
  p_rarity smallint default null,
  p_limit int default 60,
  p_offset int default 0
)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_profile uuid := auth.uid();
  v_limit int;
  v_items jsonb;
  v_total bigint;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  v_limit := least(coalesce(p_limit, 60), 200);

  select coalesce(jsonb_agg(row_to_json(t) order by t.rn), '[]'::jsonb), max(t.total_count)
    into v_items, v_total
  from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url, c.atk, c.def,
           c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           (own.card_id is not null) as owned,
           coalesce(own.owned_count, 0) as owned_count,
           coalesce(own.has_shiny, false) as owned_shiny,
           row_number() over (
             order by (own.card_id is not null) desc, c.rarity desc, c.title asc
           ) as rn,
           count(*) over() as total_count
    from public.card_catalogue c
    left join (
      select card_id, sum(count) as owned_count, bool_or(shiny) as has_shiny
      from public.collection
      where profile_id = v_profile
      group by card_id
    ) own on own.card_id = c.card_id
    where c.platform_name = p_platform
      and (p_rarity is null or c.rarity = p_rarity)
    order by (own.card_id is not null) desc, c.rarity desc, c.title asc
    limit v_limit offset p_offset
  ) t;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, 0));
end;
$$;

revoke execute on function public.browse_platform_cards(text, smallint, int, int) from public, anon;
grant execute on function public.browse_platform_cards(text, smallint, int, int) to authenticated;

-- ============================================================
-- FICHIER: 071_fix_run_duel_perf_regression.sql
-- ============================================================
-- Ludodex Online — 071 : corrige une régression de perf que J'AI introduite dans
-- 060_rpc_rate_limiting.sql (même classe de bug que la régression 058→059 sur open_booster,
-- trouvée en faisant l'audit RPC prévu au Tier 4 de la roadmap — "cheap given the pattern is now
-- known", et effectivement retrouvé au premier essai).
--
-- 060 a réécrit run_duel() en repartant par erreur du corps de 035 (le tout premier jet, tirage
-- adversaire par `ORDER BY random() LIMIT 1` sur toute la rareté) au lieu de repartir de la
-- version réellement en place (047, qui tire l'adversaire par recherche indexée sur
-- `(rarity, random_key)`, O(log n) au lieu d'un scan complet). Ce fichier réapplique le corps de
-- 047 et y garde uniquement l'ajout légitime de 060 : le throttle anti-spam en tout début.
create or replace function public.run_duel(p_deck text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid := auth.uid();
  v_state public.player_state%rowtype;
  v_card_id text;
  v_card record;
  v_opponent record;
  v_my_wins integer := 0;
  v_their_wins integer := 0;
  v_rounds jsonb := '[]'::jsonb;
  v_result text;
  v_won boolean;
  v_reward integer;
  v_duel_id uuid;
  v_threshold double precision;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;

  perform public._enforce_rate_limit('run_duel', 10, 60);

  if p_deck is null or array_length(p_deck, 1) <> 5 then
    raise exception 'Le deck doit contenir exactement 5 cartes.';
  end if;
  if array_length(p_deck, 1) <> (select count(distinct x) from unnest(p_deck) x) then
    raise exception 'Chaque carte du deck doit être différente.';
  end if;

  select * into v_state from public.player_state where profile_id = v_profile for update;
  if not found then
    raise exception 'Profil introuvable.';
  end if;

  if v_state.duel_date is distinct from current_date then
    update public.player_state set duel_date = current_date, duels_played_today = 0
      where profile_id = v_profile;
    v_state.duels_played_today := 0;
  end if;
  if v_state.duels_played_today >= 5 then
    raise exception 'Plus de duels disponibles aujourd''hui.';
  end if;

  foreach v_card_id in array p_deck loop
    if not exists (
      select 1 from public.collection
      where profile_id = v_profile and card_id = v_card_id and count > 0
    ) then
      raise exception 'Tu ne possèdes pas la carte %.', v_card_id;
    end if;

    select card_id, title, atk, def, rarity into v_card
      from public.card_catalogue where card_id = v_card_id;

    -- Tirage indexé par plage (voir 047) : exclut sa propre carte, repli en fin de plage puis
    -- repli final sur soi-même si elle est la seule de sa rareté.
    v_threshold := random();
    select card_id, title, atk, def into v_opponent
      from public.card_catalogue
      where rarity = v_card.rarity and card_id <> v_card.card_id and random_key >= v_threshold
      order by random_key
      limit 1;

    if v_opponent is null then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue
        where rarity = v_card.rarity and card_id <> v_card.card_id
        order by random_key
        limit 1;
    end if;

    if v_opponent is null then
      select card_id, title, atk, def into v_opponent
        from public.card_catalogue where rarity = v_card.rarity limit 1;
    end if;

    if (v_card.atk - v_opponent.def) > (v_opponent.atk - v_card.def) then
      v_result := 'win'; v_my_wins := v_my_wins + 1;
    elsif (v_opponent.atk - v_card.def) > (v_card.atk - v_opponent.def) then
      v_result := 'lose'; v_their_wins := v_their_wins + 1;
    else
      v_result := 'draw';
    end if;

    v_rounds := v_rounds || jsonb_build_object(
      'my_card_id', v_card.card_id, 'my_title', v_card.title, 'my_atk', v_card.atk,
      'opp_card_id', v_opponent.card_id, 'opp_title', v_opponent.title, 'opp_def', v_opponent.def,
      'result', v_result
    );
  end loop;

  v_won := v_my_wins > v_their_wins;
  v_reward := case when v_won then 40 + v_my_wins * 10 else round(40 * 0.25) end;

  update public.player_state set
    coins = coins + v_reward,
    duels_played_today = duels_played_today + 1,
    duel_wins_total = duel_wins_total + (case when v_won then 1 else 0 end),
    updated_at = now()
  where profile_id = v_profile;

  insert into public.duel_history (profile_id, won, my_wins, their_wins, reward, rounds)
    values (v_profile, v_won, v_my_wins, v_their_wins, v_reward, v_rounds)
    returning id into v_duel_id;

  perform public.create_notification(
    v_profile, 'duel_result',
    case when v_won then 'Duel gagné' else 'Duel perdu' end,
    v_my_wins || ' - ' || v_their_wins || ' · +' || v_reward || ' pièces.',
    'duel', v_duel_id::text
  );

  return jsonb_build_object(
    'id', v_duel_id, 'won', v_won, 'my_wins', v_my_wins, 'their_wins', v_their_wins,
    'reward', v_reward, 'rounds', v_rounds
  );
end;
$$;

-- ============================================================
-- FICHIER: 072_fix_image_review_queue_perf.sql
-- ============================================================
-- Ludodex Online — 072 : même audit RPC que 071, deuxième trouvaille (moindre : réservé à
-- l'équipe, appelé une carte à la fois, pas un chemin chaud joueur) — get_next_image_review_card()
-- (064/065/066) tirait sa carte de repli avec `ORDER BY random() LIMIT 1` sur tout card_catalogue
-- (239 000+ lignes) au lieu de réutiliser l'index `(rarity, random_key)` déjà posé par 047. Corrigé
-- avec la même technique de seuil + repli que run_duel (071)/open_booster.
create or replace function public.get_next_image_review_card()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb;
  v_threshold double precision;
begin
  perform public._require_elevated();

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           count(req.id) as request_count
    from public.card_image_requests req
    join public.card_catalogue c on c.card_id = req.card_id
    left join public.card_image_review r on r.card_id = c.card_id
    where not req.resolved
    group by c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url, c.atk, c.def,
             c.rarity, c.rarity_name, c.rarity_color, c.family_color,
             c.image_pos_x, c.image_pos_y, c.image_scale, r.status
    order by count(req.id) desc, min(req.created_at) asc
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  v_threshold := random();
  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done' and c.random_key >= v_threshold
    order by c.random_key
    limit 1
  ) t;
  if v_row is not null then return v_row; end if;

  select to_jsonb(t) into v_row from (
    select c.card_id, c.title, c.platform_name, c.year, c.developer, c.image_url,
           c.atk, c.def, c.rarity, c.rarity_name, c.rarity_color, c.family_color,
           c.image_pos_x, c.image_pos_y, c.image_scale,
           coalesce(r.status, 'pending') as review_status,
           0 as request_count
    from public.card_catalogue c
    left join public.card_image_review r on r.card_id = c.card_id
    where coalesce(r.status, 'pending') <> 'done'
    order by c.random_key
    limit 1
  ) t;
  return v_row;
end;
$$;

-- ============================================================
-- FICHIER: 073_support_tickets.sql
-- ============================================================
-- Ludodex Online — 073 : canal de contact/support joueur → équipe, séparé de message_reports
-- (007, qui reste réservé aux signalements ENTRE joueurs). Décision Tier 4 : un joueur avec un bug
-- ou un souci de compte doit pouvoir contacter directement l'équipe, sans passer par un autre
-- joueur à signaler.

do $$ begin
  create type support_ticket_status as enum ('open', 'in_progress', 'closed');
exception when duplicate_object then null; end $$;

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null,
  message text not null,
  status support_ticket_status not null default 'open',
  staff_note text,
  resolved_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists support_tickets_status_idx on public.support_tickets (status, created_at desc);
alter table public.support_tickets enable row level security;

drop policy if exists "support_tickets_select_own_or_staff" on public.support_tickets;
create policy "support_tickets_select_own_or_staff"
  on public.support_tickets for select
  using (
    auth.uid() = profile_id
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('moderator','admin','fondateur'))
  );
-- Pas de policy insert/update cliente directe : passe par submit_support_ticket()/
-- resolve_support_ticket() ci-dessous (throttle à l'envoi, audit à la résolution).

create or replace function public.submit_support_ticket(p_subject text, p_message text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_profile uuid := auth.uid(); v_id uuid;
begin
  if v_profile is null then
    raise exception 'Authentification requise.';
  end if;
  perform public._enforce_rate_limit('submit_support_ticket', 5, 86400);
  if p_subject is null or length(trim(p_subject)) = 0 then
    raise exception 'Sujet requis.';
  end if;
  if p_message is null or length(trim(p_message)) = 0 then
    raise exception 'Message requis.';
  end if;
  insert into public.support_tickets (profile_id, subject, message)
    values (v_profile, trim(p_subject), trim(p_message))
    returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.submit_support_ticket(text, text) from public, anon;
grant execute on function public.submit_support_ticket(text, text) to authenticated;

-- ===== Côté hub (staff, via _require_elevated déjà posé par 062/063) =====

create or replace function public.list_support_tickets(p_status text default 'open')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  perform public._require_elevated();
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select st.id, st.subject, st.message, st.status, st.staff_note, st.created_at, st.resolved_at,
           p.username
    from public.support_tickets st
    join public.profiles p on p.id = st.profile_id
    where p_status is null or st.status = p_status::support_ticket_status
    order by st.created_at desc
    limit 100
  ) t;
  return v_result;
end;
$$;

revoke execute on function public.list_support_tickets(text) from public, anon;
grant execute on function public.list_support_tickets(text) to authenticated;

create or replace function public.resolve_support_ticket(p_id uuid, p_status text, p_staff_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_ticket public.support_tickets%rowtype;
begin
  perform public._require_elevated();
  if p_status not in ('open', 'in_progress', 'closed') then
    raise exception 'Statut invalide.';
  end if;
  select * into v_ticket from public.support_tickets where id = p_id;
  if not found then
    raise exception 'Ticket introuvable.';
  end if;

  update public.support_tickets set
    status = p_status::support_ticket_status,
    staff_note = coalesce(p_staff_note, staff_note),
    resolved_by = case when p_status = 'closed' then auth.uid() else resolved_by end,
    resolved_at = case when p_status = 'closed' then now() else resolved_at end
  where id = p_id;

  if p_status = 'closed' and v_ticket.status <> 'closed' then
    perform public.create_notification(
      v_ticket.profile_id, 'support_resolved', 'Ta demande a été traitée',
      'Ton message "' || v_ticket.subject || '" a été traité par l''équipe.',
      null, null
    );
  end if;
end;
$$;

revoke execute on function public.resolve_support_ticket(uuid, text, text) from public, anon;
grant execute on function public.resolve_support_ticket(uuid, text, text) to authenticated;

create or replace function public.count_open_support_tickets()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  perform public._require_elevated();
  select count(*) into v_count from public.support_tickets where status in ('open', 'in_progress');
  return v_count;
end;
$$;

revoke execute on function public.count_open_support_tickets() from public, anon;
grant execute on function public.count_open_support_tickets() to authenticated;

