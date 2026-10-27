Le collecteur exhaustif est prêt : [collect_exhaustif.py](<C:\Users\Micka\Documents\DoktorP3st Dev Projet\Projet Divers\Ludodex\outils_igdb\collect_exhaustif.py>).

Il comprend :

- Chargement unique des 11 catalogues existants.
- Précomptage de tous les lots via `/games/count`.
- Confirmation globale avant téléchargement.
- Découpage automatique de 2010–2019 au-delà de 15 000 candidats.
- Lots dédiés rétro japonais, arcade, Mobile/Web et sorties futures.
- Sorties futures isolées avec le statut `upcoming`.
- Dédoublonnage immédiat en mémoire.
- Checkpoint atomique après chaque page de 500 résultats.
- Reprise automatique après coupure ou `Ctrl+C`.
- Limitation à environ 2,94 requêtes/s et reprise sur erreurs HTTP 429.
- Rapport consolidé généré dans `data/volumes/igdb_exhaustif_2026/RAPPORT_EXHAUSTIF.md`.
- Mode d’emploi inclus en tête du script et dans le rapport généré.

Validation locale effectuée sans lancer le collecteur ni contacter IGDB :

- Syntaxe Python valide.
- 11 sources déclarées.
- 11 sources présentes sur disque.

Pour démarrer depuis la racine de Ludodex :

```powershell
python outils_igdb\collect_exhaustif.py
```

Le script affichera les comptages et l’avertissement Mobile/Web, puis demandera :

```text
Environ X jeux vont être récupérés, continuer ? (o/n)
```

Répondre `o` ou `oui` lance la collecte. En cas d’interruption, il suffit de relancer la même commande.