# Sécurité

Ne publiez jamais une clé `service_role`, un mot de passe, un jeton OAuth, une URL de base privée ou un export contenant des données utilisateur.

Le fichier `web/js/config.example.js` ne contient que des valeurs factices. Copiez-le vers `web/js/config.js` pour votre environnement local et utilisez uniquement la clé publique/publishable de votre propre projet Supabase. Le fichier réel `config.js` est ignoré par Git.

Les scripts d'administration lisent leurs secrets depuis les variables d'environnement `SUPABASE_URL` et `SUPABASE_SERVICE_KEY`. La clé de service ne doit jamais être chargée dans le navigateur.

Avant chaque publication, exécutez les recherches décrites dans `docs/INSTALLATION.md` et contrôlez intégralement la liste produite par `git ls-files`.

Pour signaler une vulnérabilité, contactez le propriétaire du dépôt en privé via son profil GitHub. N'ouvrez pas d'issue publique contenant un secret ou une procédure d'exploitation.

