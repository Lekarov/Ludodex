# Schéma de données — Ludodex Online (Supabase)

> Conception technique, découlant de `../../SUPABASE_MIGRATION.md`. Aucune table n'est encore
> créée dans Supabase à ce stade : ce document décrit les tables, colonnes et règles d'accès
> avant d'écrire le SQL réel.

## Vue d'ensemble des tables

### `profiles`
Un profil par compte (lié à `auth.users` de Supabase Auth).

| Colonne | Type | Notes |
|---|---|---|
| id | uuid (PK) | = id de `auth.users` |
| username | text, unique | affiché publiquement (marché, chat) |
| role | enum: player / vip / moderator / admin | défaut `player`, changement réservé à l'admin |
| collection_public | boolean | défaut `false` — réglage choisi par le joueur |
| created_at | timestamptz | |

**Accès** : lecture publique des champs non sensibles (username, role, collection_public) pour que
le marché/chat fonctionnent ; écriture limitée au propriétaire pour ses propres réglages
(`collection_public`) ; le champ `role` n'est jamais modifiable par le client, seulement par
l'admin via une fonction serveur dédiée.

### `player_state`
Un état de jeu par joueur. **Aucune écriture directe du client** — uniquement via fonctions serveur.

| Colonne | Type | Notes |
|---|---|---|
| profile_id | uuid (PK, FK → profiles) | |
| coins | integer | jamais modifiable directement par le client |
| boosters_available | integer | |
| last_regen_at | timestamptz | sert à calculer la régénération côté serveur |
| updated_at | timestamptz | |

**Accès** : lecture réservée au propriétaire (les pièces sont strictement privées, voir cadrage).
Toute modification passe par une fonction (ouverture de booster, achat/vente, récompense de succès).

### `collection`
Cartes possédées par joueur.

| Colonne | Type | Notes |
|---|---|---|
| profile_id | uuid (FK → profiles) | |
| card_id | text/integer | référence catalogue statique (NAS), pas une FK SQL |
| shiny | boolean | |
| count | integer | |
| obtained_at | timestamptz | |

Clé primaire composite `(profile_id, card_id, shiny)`.

**Accès** : lecture par le propriétaire toujours ; lecture par d'autres joueurs seulement si
`profiles.collection_public = true` pour ce propriétaire. Écriture uniquement via fonctions
serveur (booster, marché).

### `achievements_unlocked`
Trace permanente des succès obtenus et de leurs récompenses versées (anti double-récompense).

| Colonne | Type | Notes |
|---|---|---|
| profile_id | uuid (FK → profiles) | |
| achievement_id | text | identifiant du succès |
| unlocked_at | timestamptz | |
| reward_granted | boolean | |
| reward_granted_at | timestamptz, nullable | |

Clé primaire composite `(profile_id, achievement_id)`.

**Accès** : lecture réservée au propriétaire. Écriture uniquement via fonction serveur (jamais
retiré ni recréé par le client).

### `market_listings`
Annonces du marché — vendeur générique (bot ou joueur), pensé pour le joueur-à-joueur futur.

| Colonne | Type | Notes |
|---|---|---|
| id | uuid (PK) | |
| seller_type | enum: bot / player | |
| seller_profile_id | uuid, nullable (FK → profiles) | null si `seller_type = bot` |
| bot_name | text, nullable | rempli si `seller_type = bot` |
| card_id | text/integer | |
| shiny | boolean | |
| listing_type | enum: sale / auction | |
| price | integer, nullable | prix fixe si `sale` |
| status | enum: active / sold / cancelled | |
| created_at | timestamptz | |

**Accès** : lecture publique (le marché est visible par tous). Écriture uniquement via fonction
serveur (création d'annonce, résolution de vente).

### `market_bids`
Offres sur une annonce de type enchère.

| Colonne | Type | Notes |
|---|---|---|
| id | uuid (PK) | |
| listing_id | uuid (FK → market_listings) | |
| bidder_type | enum: bot / player | |
| bidder_profile_id | uuid, nullable (FK → profiles) | null si bot |
| amount | integer | |
| created_at | timestamptz | |

**Accès** : lecture publique (liée à une annonce publique). Écriture uniquement via fonction
serveur (vérifie les fonds du joueur avant d'accepter l'enchère).

### `private_messages`
Messages privés entre deux joueurs.

| Colonne | Type | Notes |
|---|---|---|
| id | uuid (PK) | |
| sender_id | uuid (FK → profiles) | |
| recipient_id | uuid (FK → profiles) | |
| content | text | |
| created_at | timestamptz | |
| read_at | timestamptz, nullable | |

**Accès** : lecture réservée à l'expéditeur et au destinataire (+ un modérateur si le message est
signalé, voir `message_reports`). Écriture (insert) bloquée si le destinataire a bloqué
l'expéditeur (voir `blocks`).

### `message_reports`
Signalement d'un message privé, pour traitement par un modérateur.

| Colonne | Type | Notes |
|---|---|---|
| id | uuid (PK) | |
| message_id | uuid (FK → private_messages) | |
| reporter_id | uuid (FK → profiles) | |
| reason | text | |
| status | enum: pending / reviewed | |
| reviewed_by | uuid, nullable (FK → profiles, rôle modérateur/admin) | |
| created_at | timestamptz | sert de base à l'expiration 30 jours |

**Accès** : insertion par le joueur signalant ; lecture/mise à jour réservée aux rôles
modérateur/admin. Nettoyage automatique après 30 jours (à planifier en tâche périodique).

### `blocks`
Blocage d'un joueur par un autre.

| Colonne | Type | Notes |
|---|---|---|
| blocker_id | uuid (FK → profiles) | |
| blocked_id | uuid (FK → profiles) | |
| created_at | timestamptz | |

Clé primaire composite `(blocker_id, blocked_id)`.

**Accès** : un joueur ne gère que ses propres blocages (lecture/écriture sur les lignes où il est
`blocker_id`).

## Principe transversal (anti-triche)

Aucune des tables `player_state`, `collection`, `achievements_unlocked`, `market_listings`,
`market_bids` n'autorise d'écriture directe du client, même sur sa propre ligne. Le client ne fait
que *lire* ces tables (selon les règles ci-dessus) ; toute modification passe par une fonction
serveur (RPC Postgres `SECURITY DEFINER` ou Edge Function) qui valide la règle métier avant
d'écrire. C'est ce qui empêche un joueur de se donner des pièces, des cartes ou de fausser une
enchère en modifiant une requête côté navigateur.

## Ce qui n'est pas encore décidé (à trancher avant d'écrire le SQL réel)

- Liste exacte des fonctions serveur nécessaires (une par action de jeu : ouvrir un booster,
  acheter, vendre, enchérir, réclamer un succès) et leurs règles précises.
- Détail des policies RLS ligne par ligne (le tableau ci-dessus donne le principe, pas encore la
  syntaxe).
- Mécanisme d'expiration des signalements après 30 jours (tâche planifiée Supabase ou nettoyage
  manuel au départ).
