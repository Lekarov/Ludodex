# Base de données et migrations

## Principe

Les migrations numérotées documentent l’évolution du schéma. Elles créent tables, index, politiques RLS, fonctions métier, vues et tâches planifiées. Leur ordre fait partie du fonctionnement du projet.

## RLS

Toute table accessible depuis le navigateur doit être protégée par RLS. Une politique doit répondre clairement à quatre questions : qui peut lire, insérer, modifier et supprimer ? Testez toujours le propriétaire de la ligne, un autre joueur et un compte sans session.

## Fonctions privilégiées

Les fonctions `security definer` contournent potentiellement les droits ordinaires. Elles doivent fixer leur `search_path`, valider explicitement l’identité et les paramètres, limiter les droits `execute` et ne retourner que les champs nécessaires.

## Clés utilisées par les outils

- clé publishable : navigateur, avec RLS obligatoire ;
- clé de service : scripts d’administration uniquement, jamais dans `web/`, jamais dans Git ;
- secrets OAuth : dashboard du fournisseur et de Supabase uniquement.

## Catalogues

Les fichiers volumineux ne sont pas inclus dans cette publication. Générez vos propres données à partir de sources dont vous avez vérifié les conditions d’utilisation. Importez par lots sur une base de test et contrôlez les contraintes d’unicité avant la production.

## Sauvegardes

Ne placez jamais un dump de base dans ce dépôt. Une sauvegarde peut contenir emails, identifiants, messages, jetons révoqués ou métadonnées privées même si son nom semble anodin.

