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
