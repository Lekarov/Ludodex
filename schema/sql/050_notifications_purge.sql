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
