# Ludodex — catalogue massif IGDB

Date : 2026-09-25

## Résultat

- 15 435 jeux récupérés depuis l'API IGDB v4.
- 14 663 jeux nouveaux conservés après filtrage et déduplication.
- 14 663 IGDB ID uniques.
- Aucun doublon interne sur le couple titre normalisé + année.
- 344 jeux compatibles Nintendo DS.
- Chaque jeu possède une jaquette verticale IGDB `cover_big` (264 × 374) et une vignette carrée IGDB `thumb` (90 × 90).
- Échantillon de contrôle : 100 jeux, dont 25 jeux Nintendo DS ; 200 URLs d'images testées, 200 réponses valides de type image.

## Filtres

- au moins 5 évaluations IGDB ;
- date de première sortie obligatoire ;
- jaquette obligatoire ;
- `version_parent = null` et `parent_game = null` ;
- catégories conservées : jeu principal, extension autonome, remake, remaster et version étendue ;
- exclusion par IGDB ID déjà présent ;
- exclusion par couple titre normalisé + année contre le catalogue principal, le volume 2 et le lot courant ;
- exclusion de 116 entrées détectées par mots-clés adultes/hors sujet.

## Bilan des exclusions

- 436 IGDB ID déjà présents ;
- 190 couples titre + année déjà présents ;
- 30 doublons titre + année internes au nouveau lot ;
- 116 entrées adultes/hors sujet ;
- total final : 14 663 nouveaux jeux.

## Fichiers

- `ludodex_igdb_massif.json` : catalogue prêt pour fusion ultérieure, au schéma Ludodex.
- `ludodex_igdb_massif_rapport.json` : filtres et compteurs d'audit.
- `ludodex_igdb_massif_images_echantillon.json` : vérification HTTP des images.
- `ludodex_igdb_massif_source.json` : réponse brute IGDB conservée pour traçabilité et retraitement.

Ce lot reste séparé de `data/ludodex_catalogue.json`. Ne pas l'intégrer au site avant validation du chargeur et sauvegarde du catalogue principal.

