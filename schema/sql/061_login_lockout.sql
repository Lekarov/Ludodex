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
