# Ludodex — volume 3 IGDB

Date : 2026-09-25

## Résultat

- 10 354 fiches récupérées depuis IGDB.
- 10 015 jeux nouveaux après déduplication contre le catalogue principal, le volume 2 et le catalogue massif précédent.
- 10 015 IGDB ID uniques et aucun doublon interne titre + année.
- 355 jeux Nintendo DS.
- Années couvertes : 1969 à 2026.
- Chaque entrée possède `cover.url` en 264 × 374 et `cover.square_url` en 90 × 90.
- Échantillon : 100 jeux, 200/200 URLs d'images valides.

## Sélection

- entre 1 et 4 évaluations IGDB ;
- date de sortie et jaquette obligatoires ;
- aucun parent de version ni jeu parent ;
- catégories : jeu principal, extension autonome, remake, remaster, version étendue ;
- exclusion par IGDB ID puis par titre normalisé + année ;
- 155 entrées adultes/hors sujet écartées.

## Fichiers

- `ludodex_igdb_volume_3.json` — données normalisées prêtes pour intégration ultérieure ;
- `ludodex_igdb_volume_3_rapport.json` — filtres et exclusions ;
- `ludodex_igdb_volume_3_images_echantillon.json` — validation des images ;
- `ludodex_igdb_volume_3_source.json` — réponse brute IGDB pour traçabilité.

Le volume reste séparé jusqu'à son intégration explicite par Claude.

