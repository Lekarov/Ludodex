-- Ludodex Online — 057 : ajoute la valeur 'fondateur' à l'enum profile_role (001_extensions_and_enums.sql).
--
-- À EXÉCUTER SEUL, DANS SA PROPRE REQUÊTE — PAS DANS LE PASTE GROUPÉ ALL_IN_ONE.
-- Postgres n'autorise pas de manière fiable l'usage d'une valeur d'enum tout juste ajoutée par
-- ALTER TYPE ... ADD VALUE dans la même transaction (le SQL Editor de Supabase envoie tout un
-- paste comme une seule transaction implicite) : 058_profile_vip_and_rank.sql référence
-- 'fondateur' dans une policy, donc cette valeur doit déjà exister et être validée AVANT.
-- Lance ce fichier, attends qu'il termine, puis lance 058 (ou le reste de l'ALL_IN_ONE).

alter type profile_role add value if not exists 'fondateur';
