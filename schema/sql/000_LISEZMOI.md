# SQL Ludodex Online

Pour une base neuve, utilisez de préférence `setup.ps1` à la racine. Il exécute automatiquement les migrations `001` à `074` dans l’ordre, puis importe les catalogues complets.

Installation manuelle :

1. exécuter chaque fichier SQL dans l’ordre numérique ;
2. importer `schema/catalogue_import/card_catalogue.csv` dans `public.card_catalogue` ;
3. importer `schema/catalogue_import/character_catalogue.csv` dans `public.character_catalogue` ;
4. pour inclure les descriptions dans l’import, utiliser `tools/merge_character_descriptions.py` comme le fait `setup.ps1` ;
5. configurer dans le dashboard les fournisseurs OAuth, les URL de redirection et les hooks explicitement demandés par les commentaires des migrations ;
6. tester les politiques RLS avec plusieurs comptes fictifs avant toute ouverture publique.

Les migrations reflètent l’historique du produit. Elles sont prévues ici pour une installation neuve. Ne rejouez jamais aveuglément l’ensemble sur une base de production déjà remplie.

`016_card_catalogue_foreign_keys.sql` peut être appliqué avant l’import sur une base neuve, puisque les tables métier sont encore vides. Sur une base existante issue d’une ancienne version, suivez impérativement les commentaires de `015` et `016`.

Certaines fonctions nécessitent des étapes manuelles propres au dashboard Supabase, notamment les fournisseurs OAuth, les hooks Auth et les extensions/tâches planifiées disponibles selon le forfait.
