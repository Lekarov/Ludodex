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
