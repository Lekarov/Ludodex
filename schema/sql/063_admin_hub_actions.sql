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

