Le script a été créé ici : [collect_modern_rated_2026.py](C:/Users/Micka/Documents/DoktorP3st%20Dev%20Projet/Projet%20Divers/Ludodex/outils_igdb/collect_modern_rated_2026.py)

Périmètre retenu :

- Dates : 01/01/2011 → 27/09/2026. Je n’ai pas étendu avant 2011, car les volumes existants couvrent déjà largement le rétro ; le manque identifié concerne les jeux modernes notés.
- 35 plateformes :
  - PC : Windows, macOS, Linux
  - Consoles : Wii, PS3, Xbox 360, PSP, 3DS/New 3DS, Wii U, Vita, PS4/PS5, Xbox One/Series, Switch/Switch 2
  - Mobile/web : Android, iOS, Windows Phone, BlackBerry OS, Legacy Mobile Device, navigateur
  - VR : Gear VR, Windows Mixed Reality, SteamVR, Daydream, PSVR/PSVR2, Quest/Quest 2/Quest 3, visionOS
  - Cloud : OnLive et Stadia

Le script :

- lit dynamiquement les 12 sources actuelles de `CATALOGUE_SOURCES` et ajoute `igdb_modern_2026` si nécessaire ;
- conserve simultanément les clés et les `igdb_id` pour le dédoublonnage ;
- valide les 35 IDs via `/v4/platforms` ;
- utilise `/games/count`, affiche l’estimation, puis demande `(o/n)` ;
- accepte toute la gamme de notes dès `total_rating_count >= 1` ;
- sauvegarde un JSON `PARTIEL` et un curseur après chaque page ;
- produit le JSON final et le rapport demandé avec rejets, plateformes et années ;
- utilise `EPOCH + timedelta(seconds=ts)`, sans appel à `datetime.fromtimestamp()`.

Commande :

```powershell
python outils_igdb/collect_modern_rated_2026.py
```

Validation locale effectuée : compilation Python, analyse AST, extraction des sources et chargement des 203 438 fiches existantes. La collecte réseau n’a pas été lancée.

Limites à connaître : le volume réel reste inconnu jusqu’au précomptage IGDB, les résultats dépendent de l’état d’IGDB au lancement, et une grosse collecte peut prendre du temps ou rencontrer des limitations HTTP 429 — les reprises et tentatives automatiques sont prévues.