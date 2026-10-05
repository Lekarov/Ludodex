# Ludodex Online — code source public assaini

Ludodex est un jeu web de collection de cartes inspirées de l’univers du jeu vidéo. Les joueurs créent un compte, ouvrent des boosters, complètent leur collection, consultent le catalogue, échangent des cartes, utilisent un marché interne, lancent des duels et interagissent avec les autres membres.

Cette publication contient le code du site, les migrations PostgreSQL/Supabase et les scripts de génération. Elle ne contient volontairement aucun secret, aucune configuration active, aucune donnée utilisateur, aucun export de production et aucune adresse d’infrastructure réelle.

> **Utilisation du code : contactez d’abord le propriétaire du dépôt via son profil GitHub.** Le code est visible à des fins de consultation et de démonstration, mais sa copie, sa modification, sa redistribution ou son hébergement ne sont pas autorisés sans accord écrit préalable. Consultez `LICENSE`.

## Aperçu

Le projet utilise une architecture volontairement simple :

- frontend statique en HTML, CSS et JavaScript natif ;
- Supabase pour l’authentification, PostgreSQL, les règles RLS et les fonctions métier ;
- logique sensible exécutée côté base via des fonctions SQL/RPC ;
- serveur Python local minimal uniquement pour le développement ;
- catalogue généré hors ligne puis importé en base.

Les captures anonymisées se trouvent dans [`docs/screenshots`](docs/screenshots) lorsqu’elles sont disponibles.

## Fonctions principales

- inscription, connexion, récupération et suppression de compte ;
- profils, préférences et rôles ;
- boosters et économie virtuelle ;
- collection, album, catalogue et fiches détaillées ;
- raretés et variantes visuelles ;
- marché, ventes directes et enchères ;
- échanges entre joueurs ;
- duels et historique ;
- succès, notifications, amis et messagerie ;
- outils d’administration et de modération ;
- catalogue de jeux et catalogue de personnages unifiés.

## Organisation du dépôt

```text
Ludodex-Public/
├── web/                         # application servie au navigateur
│   ├── assets/                  # éléments graphiques propres au projet
│   ├── css/                     # design system et styles par écran
│   ├── img/                     # logo
│   ├── js/                      # logique cliente
│   │   ├── catalogue/           # rendu et fonctions du catalogue
│   │   └── config.example.js    # configuration factice à copier localement
│   └── *.html                   # pages publiques et pages connectées
├── schema/
│   ├── sql/                     # migrations numérotées
│   ├── catalogue_import/        # générateurs et scripts d’import
│   ├── ALL_IN_ONE_skip016.sql   # assemblage historique, voir avertissement
│   └── SCHEMA.md                # description détaillée des données
├── docs/                        # tutoriels et captures anonymisées
├── serve_nocache.py             # serveur de développement sans cache
├── SECURITY.md                  # règles de sécurité
└── LICENSE                      # tous droits réservés
```

## Démarrage rapide

### 1. Préparer votre propre projet Supabase

Créez un projet Supabase séparé. N’utilisez jamais une base de production pour tester les migrations.

Exécutez les migrations de `schema/sql/` dans l’ordre numérique. Certaines migrations historiques ont des contraintes d’ordre et des étapes manuelles : lisez d’abord [`docs/DATABASE.md`](docs/DATABASE.md) et `schema/sql/000_LISEZMOI.md`.

### 2. Configurer le frontend

Copiez :

```powershell
Copy-Item web/js/config.example.js web/js/config.js
```

Puis remplacez uniquement les deux valeurs factices par celles de **votre** projet :

```js
const SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "YOUR_SUPABASE_PUBLISHABLE_KEY";
```

La clé publishable est conçue pour le navigateur, mais elle donne accès aux opérations autorisées par vos politiques RLS. Une mauvaise politique RLS reste donc une faille. La clé `service_role` ne doit jamais se trouver dans `web/`.

### 3. Lancer le site en local

Depuis la racine :

```powershell
python serve_nocache.py
```

Ouvrez ensuite `http://localhost:8082/`. Le serveur désactive le cache pour faciliter le développement ; ce n’est pas un serveur de production.

### 4. Importer un catalogue

Les gros exports réels ne sont pas publiés. Les scripts de `schema/catalogue_import/` montrent comment construire les fichiers attendus. Vérifiez les licences et conditions d’utilisation de chaque source avant de récupérer ou republier ses données et images.

Les scripts d’administration utilisent exclusivement des variables d’environnement :

```powershell
$env:SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co"
$env:SUPABASE_SERVICE_KEY = "YOUR_SERVICE_ROLE_KEY"
node schema/catalogue_import/backfill_character_description.js
```

Ne placez jamais la clé de service dans un fichier suivi par Git. Supprimez les variables de votre terminal après utilisation et faites tourner les scripts uniquement sur un environnement maîtrisé.

## Comment fonctionne l’application

### Authentification

`web/js/supabaseClient.js` initialise le client à partir de `config.js`. Les pages de connexion et d’inscription utilisent Supabase Auth. Les pages privées vérifient la session avant de charger les données du joueur.

### Sécurité des données

Le navigateur n’est pas considéré comme fiable. Les politiques Row Level Security déterminent quelles lignes chaque compte peut lire ou modifier. Les actions économiques importantes sont regroupées dans des fonctions SQL/RPC afin d’être transactionnelles et de limiter les manipulations côté client.

### Boosters et collection

L’ouverture d’un booster appelle une fonction serveur qui sélectionne les cartes, applique les règles de rareté et enregistre le résultat. Le frontend ne fait que demander l’ouverture puis afficher l’animation et les cartes retournées. La collection agrège ensuite les quantités possédées et les métadonnées du catalogue.

### Catalogue et rendu des cartes

Le catalogue de jeux et celui des personnages sont exposés par une vue unifiée. Les modules de `web/js/catalogue/` centralisent le rendu, les constantes, les dialogues de détail et les interactions associées. Les styles de rareté se trouvent principalement dans `web/css/card.css`.

### Marché et échanges

Les annonces, enchères et échanges sont stockés en base. Les fonctions SQL contrôlent la propriété des cartes, les soldes, les états de transaction et les conflits concurrents. Les écrans clients affichent les résultats sans être l’autorité sur l’économie.

### Social, messagerie et modération

Les relations, conversations, messages, signalements et notifications ont leurs propres tables et politiques. Les droits d’administration reposent sur les rôles en base, jamais sur le simple fait de masquer ou afficher un bouton dans l’interface.

### Duels et succès

Le serveur valide les limites, sélectionne les cartes et enregistre le résultat. Les succès et notifications sont créés à partir d’événements contrôlés côté base pour éviter qu’un navigateur puisse s’attribuer lui-même une récompense.

## Déploiement

Le dossier `web/` peut être servi par un hébergeur statique. Avant toute mise en ligne :

1. configurez les URL autorisées dans Supabase Auth ;
2. adaptez la Content Security Policy de chaque page à votre domaine et à votre projet ;
3. remplacez les documents juridiques génériques après validation professionnelle ;
4. vérifiez toutes les politiques RLS avec plusieurs comptes de test ;
5. contrôlez les permissions des rôles `anon`, `authenticated` et des fonctions `security definer` ;
6. activez les fournisseurs OAuth uniquement après avoir configuré leurs propres secrets côté dashboard ;
7. remplacez les placeholders de `robots.txt` et `sitemap.xml` ;
8. exécutez l’audit de secrets décrit dans `SECURITY.md`.

## Données absentes de cette publication

Pour protéger la vie privée et éviter une redistribution involontaire, ce dépôt ne contient pas :

- clés Supabase, IGDB/Twitch ou OAuth ;
- URL, identifiants ou références de projets réels ;
- emails, noms, adresses ou comptes personnels ;
- données de joueurs, messages, sessions ou journaux ;
- exports complets de base ou fichiers de sauvegarde ;
- fichiers de travail et comptes rendus internes ;
- gros catalogues CSV/JSON et médias provenant de tiers.

## Documentation détaillée

- [`docs/INSTALLATION.md`](docs/INSTALLATION.md) — installation guidée et contrôle avant publication ;
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — parcours d’une requête et responsabilités ;
- [`docs/DATABASE.md`](docs/DATABASE.md) — migrations, RLS et fonctions métier ;
- [`SECURITY.md`](SECURITY.md) — secrets et signalement responsable ;
- [`schema/SCHEMA.md`](schema/SCHEMA.md) — tables et relations historiques.

## Statut et avertissement

Le projet est fourni comme démonstration technique, sans garantie. Les migrations reflètent l’évolution historique du produit et doivent être relues avant une nouvelle installation. Les pages juridiques fournies sont des modèles neutres et ne constituent pas un conseil juridique.

