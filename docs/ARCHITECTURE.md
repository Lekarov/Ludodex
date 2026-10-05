# Architecture

## Vue d’ensemble

```text
Navigateur
  │
  ├── pages HTML + modules JavaScript
  ├── client Supabase configuré localement
  │
  ▼
Supabase Auth ── identité et session
  │
  ▼
PostgREST / RPC
  │
  ├── politiques RLS : visibilité ligne par ligne
  ├── fonctions SQL : règles métier transactionnelles
  ├── tables joueur : profil, économie, collection, social
  └── catalogue : données publiques en lecture
```

## Répartition des responsabilités

Le frontend gère la navigation, le rendu, l’accessibilité, les formulaires et les animations. Il ne doit jamais décider seul qu’une récompense est acquise, qu’un solde est suffisant ou qu’une carte change de propriétaire.

La base gère les invariants : autorisations, propriété, soldes, limites, états et transactions concurrentes. Une action complexe doit idéalement être une fonction RPC atomique plutôt qu’une suite de mises à jour indépendantes depuis le navigateur.

## Chargement d’une page privée

1. `config.js` fournit l’URL et la clé publique du projet local.
2. `supabaseClient.js` crée le client.
3. le module de page récupère la session ;
4. les requêtes sont envoyées avec le jeton du compte ;
5. PostgreSQL applique les politiques RLS ;
6. le module transforme la réponse en composants visuels.

## Catalogue

Les scripts hors ligne normalisent les sources et produisent des imports structurés. Le navigateur interroge des tables ou vues déjà préparées : il ne télécharge pas les sources originales et ne calcule pas tout le catalogue localement.

## Design

`tokens-site.css` et `theme.css` contiennent les variables globales. `layout.css` et `app-shell.css` structurent l’application. Les feuilles spécialisées gèrent les cartes, boosters, dialogues, marché, social et administration.

