# LudodexCoverEditor — CLAUDE.md

Petit outil FastAPI, séparé du projet Ludodex, pour remplacer/recadrer manuellement la
jaquette d'un jeu quand la version IGDB ne convient pas.

**Port :** 8091 (voir `config.py`).
**Local Windows :** `C:\Users\Micka\Documents\DoktorP3st Dev Projet\App DoktorTV\LudodexCoverEditor\`

## Ce que l'outil touche, et ce qu'il ne touche jamais

- **Lit en lecture seule** les catalogues réels de Ludodex (`config.CATALOGUE_FILES`) —
  jamais de modification, jamais de copie sur disque.
- **Écrit le vrai fichier utilisé par le site** : `Ludodex/site/assets/overrides/cover-overrides.json`
  (`core/overrides_store.py`). C'est une surcouche par id (`{coverUrl?, objectPosition?}`),
  jamais une modification des sources IGDB de Codex. Le site l'applique automatiquement au
  chargement (`catalogue-loader.js`), rien à faire côté site après un enregistrement.
- **Sa propre progression** (`data/progress.json`, `core/progress_store.py`) : quels jeux ont
  déjà été passés en revue, pour que "Suivante" reprenne toujours où on s'était arrêté, sur
  plusieurs sessions.

## Architecture

```
config.py            Chemins Ludodex, fichier de surcouche, port.
main.py               App FastAPI, monte /ludodex-css (lecture seule des vraies feuilles de
                      style du site, pour un aperçu de recadrage identique à la vraie carte).
api/routes.py         Page unique (/), recherche (/api/search), enregistrement (/save,
                      /skip, /clear).
core/catalogue.py      Fusion en lecture seule des catalogues réels (id/titre/plateformes/
                       jaquette), mise en cache mémoire (relancer l'outil si Codex ajoute
                       un volume).
core/overrides_store.py Lecture/écriture atomique du fichier de surcouche réel.
core/progress_store.py  File "à faire/fait" + calcul de "next_id".
templates/editor.html   Page : aperçu carte réelle, recadrage au clic, suggestions (jaquette
                         IGDB grande + miniature), champ lien libre.
static/app.js            Logique du clic de recadrage + recherche + choix d'une suggestion.
```

## Points critiques

- **Recadrage** : le clic dans l'aperçu calcule un pourcentage X/Y écrit tel quel dans
  `object-position` — même format que `card.css` (`50% 20%`) et que ce que
  `catalogue-loader.js` lit dans `objectPosition`. Ne pas changer ce format sans adapter les
  deux côtés.
- **Écriture atomique** (`tempfile.mkstemp` + `os.replace` + `fsync`) sur les deux fichiers
  d'état, pour ne jamais laisser un JSON à moitié écrit si l'outil est coupé en pleine
  sauvegarde.
- **`core/catalogue.py` mémorise le catalogue fusionné pour toute la durée du process**
  (`lru_cache`) : si Codex ajoute un nouveau volume pendant que l'outil tourne, redémarrer
  l'outil pour le voir apparaître.
- **Ne jamais ajouter ce fichier de surcouche comme "source de catalogue"** côté site — c'est
  le même piège que celui déjà rencontré une fois avec les descriptions (voir
  `Ludodex/coordination/ETAT_CLAUDE_2026-09-25_bugfix_descriptions.md`) : un fichier `{id:
  {...}}` sans titre ni plateforme ni jaquette créerait des fiches fantômes s'il était
  fusionné comme catalogue plutôt qu'en surcouche.

## Lancer l'outil

```
pip install -r requirements.txt
python main.py
```
Puis ouvrir `http://localhost:8091/`.
