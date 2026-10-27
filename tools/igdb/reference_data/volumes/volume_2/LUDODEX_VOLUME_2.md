# Ludodex — volume 2 Steam

Date de préparation : 2026-09-25

## Résultat

- 33 nouveaux jeux Steam, conservés dans un fichier séparé du catalogue principal.
- 33 AppID uniques et absents de `data/ludodex_catalogue.json`.
- Aucun doublon exact de titre normalisé avec les 5 062 jeux existants.
- 33 fiches confirmées comme `type=game` et contenant le genre `Indie` sur Steam.
- 33 capsules vérifiées : réponse HTTP 200 et type MIME `image/*`.
- Aucun appel n'a modifié le catalogue principal ni le site.

## Sources et filtres

- Découverte : SteamSpy, endpoint `all`, page 2.
- Validation : endpoint public Steam Store `appdetails`, une fiche par AppID.
- Seuils : au moins 8 000 avis SteamSpy et au moins 85 % d'avis positifs.
- Exclusions : AppID déjà présent, produit autre que `game`, genre Indie absent de Steam, prologue/démo/outil, contenu adulte manifeste, capsule absente.
- Les estimations de propriétaires SteamSpy sont conservées comme estimations, jamais comme ventes.

## Fichiers

- `ludodex_volume_2.json` : 33 entrées au même format que le catalogue normalisé, prêtes pour une fusion ultérieure par clé `steam:<AppID>`.
- `ludodex_volume_2_rapport.json` : filtres, exclusions et éventuelles erreurs de requête.
- `ludodex_volume_2_images.json` : résultat de la validation HTTP des 33 capsules.

## Intégration recommandée

Ne pas intégrer ce volume tant que Claude n'a pas terminé le chargement de `data/ludodex_catalogue.json`. Pour l'ajout, fusionner les objets JSON par clé ; refuser toute clé déjà existante et conserver le journal du volume.

