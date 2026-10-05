# Installation complète

## Prérequis

- Python 3 pour le serveur local ;
- Node.js uniquement pour les scripts de génération/import ;
- un projet Supabase neuf ;
- un navigateur récent ;
- Git pour versionner votre configuration, sans jamais versionner les secrets.

## Base de données

1. Créez un projet Supabase de test.
2. Ouvrez `schema/sql/000_LISEZMOI.md`.
3. Exécutez les migrations dans l’ordre numérique.
4. Effectuez les étapes manuelles indiquées dans les commentaires des migrations : fournisseurs OAuth, hooks Auth, extensions et tâches planifiées peuvent nécessiter le dashboard.
5. Testez les règles RLS avec au minimum deux comptes joueurs et un compte d’administration de test.

Le fichier `ALL_IN_ONE_skip016.sql` est conservé comme commodité historique. Pour comprendre et diagnostiquer l’installation, préférez les fichiers numérotés. Ne lancez jamais un lot SQL sans l’avoir lu sur une base contenant déjà des données.

## Frontend

1. Copiez `web/js/config.example.js` vers `web/js/config.js`.
2. Ajoutez l’URL et la clé publishable de votre projet de test.
3. Ne modifiez pas `.gitignore` pour forcer l’ajout de `config.js`.
4. Lancez `python serve_nocache.py`.
5. Ouvrez `http://localhost:8082/`.

## Tests fonctionnels recommandés

Créez des comptes fictifs qui ne réutilisent aucune adresse ou mot de passe personnel, puis testez :

- inscription, connexion, déconnexion, récupération et suppression ;
- ouverture simultanée de boosters ;
- collection et pagination du catalogue ;
- création, achat, enchère et expiration d’annonce ;
- proposition, acceptation et refus d’échange ;
- duel, limite quotidienne et historique ;
- ajout d’ami, blocage et signalement ;
- messagerie et expiration ;
- permissions joueur, modérateur et administrateur ;
- refus des accès directs non autorisés via l’API REST.

## Audit avant commit

Contrôlez les fichiers qui vont réellement être publiés :

```powershell
git status --short
git ls-files
git grep -n -I -E "sb_secret_|service_role|SUPABASE_SERVICE_KEY|client_secret|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY"
git grep -n -I -E "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
git grep -n -I -E "https://[a-z0-9-]+\.supabase\.co"
```

Les noms de variables et les placeholders documentaires peuvent apparaître ; aucune valeur réelle ne doit apparaître. Inspectez chaque résultat manuellement.

Vérifiez aussi les fichiers non suivis, car un secret ignoré par Git reste présent sur votre machine :

```powershell
Get-ChildItem -Recurse -Force -File | Where-Object {
  $_.Name -match '^\.env' -or $_.Extension -in '.pem','.key','.pfx','.db','.sqlite'
}
```

## Rotation en cas de doute

Si une clé a déjà été copiée dans un commit ou envoyée à un tiers, la supprimer du dernier état ne suffit pas. Révoquez-la immédiatement dans le service concerné, générez-en une nouvelle et nettoyez l’historique Git avant toute publication.

