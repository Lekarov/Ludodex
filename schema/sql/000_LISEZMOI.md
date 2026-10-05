# SQL Ludodex Online — à exécuter vous-même

Ces fichiers ne sont **pas exécutés automatiquement**. Personne ne s'est connecté à votre projet
Supabase pour les lancer. Ce sont des fichiers prêts à être collés, un par un et dans l'ordre,
dans l'éditeur SQL de votre dashboard Supabase (Project → SQL Editor), quand vous serez prêt.

Ordre d'exécution :

1. `001_extensions_and_enums.sql` — types réutilisés par les autres tables
2. `002_profiles.sql` — profils + création automatique à l'inscription
3. `003_player_state.sql` — pièces, boosters
4. `004_collection.sql` — cartes possédées
5. `005_achievements.sql` — succès + trace de récompense
6. `006_market.sql` — annonces et enchères
7. `007_messages_and_moderation.sql` — messages privés, signalements, blocages

Recommandation : testez d'abord sur un projet Supabase séparé (pas le projet de production), ou
au minimum relisez chaque fichier avant de l'exécuter — vous pouvez me redemander une relecture
avant de lancer quoi que ce soit.

Ce qui **manque encore volontairement** dans ces fichiers (à faire dans une étape suivante,
séparée) :
- Les fonctions serveur (RPC) qui valident les actions de jeu (ouvrir un booster, acheter,
  vendre, enchérir, réclamer un succès) — ces tables n'ont aucune écriture cliente possible tant
  que ces fonctions n'existent pas, ce qui est voulu (pas de triche possible par défaut).
- Le nettoyage automatique des signalements après 30 jours (nécessite l'extension `pg_cron`,
  à activer depuis le dashboard si vous le souhaitez).
- Le flux Google/Discord (configuration dans Authentication → Providers du dashboard, pas du SQL).
