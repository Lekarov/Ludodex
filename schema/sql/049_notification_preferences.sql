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
