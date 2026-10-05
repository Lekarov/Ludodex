-- Ludodex Online — 036 : bio multilingue des cartes + genres en repli
-- card_catalogue était volontairement léger jusqu'ici (voir 015 : pas de vraie bio en base, la
-- fiche détail affichait développeur/plateforme/année à la place). Ajout de colonnes de résumé
-- par langue, remplies séparément via un import CSV (voir outils_igdb/fetch_descriptions.py +
-- translate_descriptions.py, propriété Codex) — pas de traduction faite ici, juste la place pour
-- les recevoir. NULL tant qu'aucun résumé IGDB n'existe pour ce jeu (beaucoup n'en ont pas) : le
-- client doit prévoir ce cas, pas en faire une erreur.
-- `genres` : repli d'affichage quand il n'y a ni description_en ni description_fr — les genres
-- IGDB (ex. "Shooter, Indie, Arcade") sont déjà présents dans les fichiers data/ mais jamais
-- importés jusqu'ici (generate_card_catalogue.js les ignorait). Stocké en texte simple, déjà
-- joint par virgule, pour rester cohérent avec le reste de card_catalogue (pas de colonne array).

alter table public.card_catalogue
  add column if not exists description_en text,
  add column if not exists description_fr text,
  add column if not exists genres text;
