"""Chemins et constantes. Rien d'autre ici : les modules lisent ce fichier, jamais l'inverse."""
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

# Dossier réel du projet Ludodex (lu et écrit directement, pas de copie).
LUDODEX_ROOT = Path(r"C:\Users\Micka\Documents\DoktorP3st Dev Projet\Projet Divers\Ludodex")
LUDODEX_SITE = LUDODEX_ROOT / "site"
LUDODEX_DATA = LUDODEX_ROOT / "data"

# Catalogues réels (lecture seule) : même liste que site/js/config/constants.js
# (CATALOGUE_SOURCES), en chemins filesystem. Garder synchronisé à la main si
# Codex ajoute un nouveau volume côté site.
CATALOGUE_FILES = [
    (LUDODEX_DATA / "volumes/igdb_massif_14663/ludodex_igdb_massif.json", "catalogue massif IGDB"),
    (LUDODEX_DATA / "volumes/volume_2/ludodex_volume_2.json", "volume 2"),
    (LUDODEX_DATA / "ludodex_catalogue.json", "catalogue principal"),
    (LUDODEX_DATA / "volumes/igdb_volume_3_10015/ludodex_igdb_volume_3.json", "volume 3"),
    (LUDODEX_DATA / "volumes/igdb_recent_2020_2026/ludodex_igdb_recent_2020_2026.json", "jeux récents 2020-2026"),
    (LUDODEX_DATA / "volumes/igdb_recent_2020_2026_2/ludodex_igdb_recent_2020_2026_2.json", "jeux récents 2020-2026 (suite)"),
    (LUDODEX_DATA / "volumes/igdb_gamecube_ds_psp/ludodex_igdb_gamecube_ds_psp.json", "GameCube DS PSP"),
    (LUDODEX_DATA / "volumes/igdb_ps2_wii_3ds_vita_dreamcast_gba/ludodex_igdb_ps2_wii_3ds_vita_dreamcast_gba.json", "PS2 Wii 3DS Vita Dreamcast GBA"),
    (LUDODEX_DATA / "volumes/igdb_ps3_ps4_x360_xone_wiiu_switch/ludodex_igdb_ps3_ps4_x360_xone_wiiu_switch.json", "PS3 PS4 Xbox Wii U Switch"),
    (LUDODEX_DATA / "volumes/igdb_modern_rare/ludodex_igdb_modern_rare.json", "sélection raretés consoles modernes"),
]

# Le vrai fichier utilisé par le site (surcouche jaquettes, jamais les sources IGDB).
OVERRIDES_FILE = LUDODEX_SITE / "assets/overrides/cover-overrides.json"

# État propre à cet outil (file de progression), pas partagé avec le site.
PROGRESS_FILE = BASE_DIR / "data/progress.json"

PORT = 8091
