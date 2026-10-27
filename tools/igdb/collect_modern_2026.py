#!/usr/bin/env python3
"""Construit le volume IGDB moderne 2026, sans modifier les volumes existants."""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "outils_igdb" / "config.json"
TOKEN_FILE = ROOT / "outils_igdb" / "token.json"
OUT_DIR = ROOT / "data" / "volumes" / "igdb_modern_2026"
OUT_FILE = OUT_DIR / "ludodex_igdb_modern_2026.json"
PARTIAL_FILE = OUT_DIR / "ludodex_igdb_modern_2026_PARTIEL.json"
REPORT_FILE = OUT_DIR / "RAPPORT_IGDB_MODERN_2026.md"

PAGE = 500
PAUSE = 0.34
START_TS = int(datetime(2011, 1, 1, tzinfo=timezone.utc).timestamp())
END_TS = int(datetime(2026, 9, 27, 23, 59, 59, tzinfo=timezone.utc).timestamp())
ALLOWED_TYPES = (0, 4, 8, 9, 10)
PLATFORM_IDS = (3, 6, 14, 48, 49, 130, 167, 169, 508)

EXISTING_FILES = (
    "data/ludodex_catalogue.json",
    "data/volumes/volume_2/ludodex_volume_2.json",
    "data/volumes/igdb_gamecube_ds_psp/ludodex_igdb_gamecube_ds_psp.json",
    "data/volumes/igdb_massif_14663/ludodex_igdb_massif.json",
    "data/volumes/igdb_modern_rare/ludodex_igdb_modern_rare.json",
    "data/volumes/igdb_ps2_wii_3ds_vita_dreamcast_gba/ludodex_igdb_ps2_wii_3ds_vita_dreamcast_gba.json",
    "data/volumes/igdb_ps3_ps4_x360_xone_wiiu_switch/ludodex_igdb_ps3_ps4_x360_xone_wiiu_switch.json",
    "data/volumes/igdb_recent_2020_2026/ludodex_igdb_recent_2020_2026.json",
    "data/volumes/igdb_recent_2020_2026_2/ludodex_igdb_recent_2020_2026_2.json",
    "data/volumes/igdb_volume_3_10015/ludodex_igdb_volume_3.json",
)


def atomic_json(path, value):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def load_existing():
    keys, ids, records = set(), set(), 0
    for rel in EXISTING_FILES:
        data = json.loads((ROOT / rel).read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise RuntimeError(f"Format inattendu: {rel}")
        records += len(data)
        keys.update(data.keys())
        for key, card in data.items():
            if isinstance(key, str) and key.startswith("igdb:"):
                try:
                    ids.add(int(key.split(":", 1)[1]))
                except ValueError:
                    pass
            if isinstance(card, dict) and card.get("igdb_id") is not None:
                try:
                    ids.add(int(card["igdb_id"]))
                except (TypeError, ValueError):
                    pass
    return keys, ids, records


def get_token(cfg, incidents):
    if TOKEN_FILE.exists():
        saved = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        if saved.get("expires_at", 0) > time.time() + 3600:
            incidents.append("Jeton existant réutilisé (encore valide).")
            return saved["access_token"]
    params = urllib.parse.urlencode({
        "client_id": cfg["client_id"], "client_secret": cfg["client_secret"],
        "grant_type": "client_credentials",
    })
    req = urllib.request.Request(f"https://id.twitch.tv/oauth2/token?{params}", method="POST")
    with urllib.request.urlopen(req, timeout=30) as response:
        data = json.load(response)
    atomic_json(TOKEN_FILE, {
        "access_token": data["access_token"],
        "expires_at": time.time() + data.get("expires_in", 0),
    })
    incidents.append("Jeton expiré ou proche de l'expiration : nouveau jeton généré.")
    return data["access_token"]


def api(endpoint, body, token, client_id, incidents):
    for attempt in range(6):
        req = urllib.request.Request(
            f"https://api.igdb.com/v4/{endpoint}", data=body.encode(), method="POST",
            headers={"Client-ID": client_id, "Authorization": f"Bearer {token}",
                     "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            if exc.code == 429:
                incidents.append(f"Rate limit HTTP 429 à la tentative {attempt + 1}; attente appliquée.")
                time.sleep(1 + attempt)
                continue
            raise RuntimeError(f"IGDB {endpoint}: HTTP {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt < 2:
                incidents.append(f"Erreur réseau temporaire ({exc}); nouvelle tentative.")
                time.sleep(2 + attempt)
                continue
            raise RuntimeError(f"Réseau IGDB indisponible: {exc}") from exc
    raise RuntimeError("Rate limit IGDB persistant après 6 tentatives")


def developer(game):
    companies = game.get("involved_companies") or []
    for item in companies:
        if item.get("developer") and item.get("company", {}).get("name"):
            return item["company"]["name"]
    return "Inconnu"


def steam_appid(game):
    for external in game.get("external_games") or []:
        if external.get("category") == 1 and str(external.get("uid", "")).isdigit():
            return int(external["uid"])
    return None


def card(game):
    gid = int(game["id"])
    image_id = game["cover"]["image_id"]
    platforms = sorted({p["name"] for p in game.get("platforms", []) if p.get("name")})
    rating = game.get("aggregated_rating") or game.get("total_rating")
    return {
        "id": f"igdb:{gid}", "igdb_id": gid, "steam_appid": steam_appid(game),
        "title": game["name"],
        "year": datetime.fromtimestamp(game["first_release_date"], tz=timezone.utc).year,
        "developer": developer(game), "platforms": platforms,
        "genres": [x["name"] for x in game.get("genres", []) if x.get("name")],
        "themes": [x["name"] for x in game.get("themes", []) if x.get("name")],
        "cover": {
            "url": f"https://images.igdb.com/igdb/image/upload/t_cover_big/{image_id}.jpg",
            "square_url": f"https://images.igdb.com/igdb/image/upload/t_thumb/{image_id}.jpg",
            "source": "igdb", "image_id": image_id,
        },
        "source_page": f"https://www.igdb.com/games/{game.get('slug', '')}",
        "verification_status": "verified", "duplicate_of": None,
        "merged_from": [f"igdb:games:{gid}"], "conflict_fields": [],
        "last_updated_source": f"igdb:games:{gid}", "added_at": "2026-09-27",
        "selection": {
            "rating": round(rating, 2) if rating is not None else None,
            "rating_count": game["total_rating_count"], "minimum_rating_count": 1,
        },
    }


def report(existing_records, existing_keys, existing_ids, raw, rejected, cards, incidents, partial=False, error=None):
    years = Counter(str(v["year"]) for v in cards.values())
    platforms = Counter(p for v in cards.values() for p in v["platforms"])
    status = "PARTIEL — collecte interrompue" if partial else "TERMINÉ"
    lines = [
        "# Rapport — volume IGDB moderne 2026", "", f"Statut : **{status}**", "",
        "## Résultat", "",
        f"- Fiches inspectées dans les 10 fichiers existants : **{existing_records:,}**".replace(",", " "),
        f"- Clés existantes : **{len(existing_keys):,}**".replace(",", " "),
        f"- Identifiants IGDB existants uniques : **{len(existing_ids):,}**".replace(",", " "),
        f"- Candidats bruts reçus d'IGDB : **{raw:,}**".replace(",", " "),
        f"- Rejetés car déjà présents (filtrage local) : **{rejected:,}**".replace(",", " "),
        f"- Fiches finales écrites : **{len(cards):,}**".replace(",", " "), "",
        "## Périmètre", "",
        "- Dates de sortie : du 1er janvier 2011 au 27 septembre 2026.",
        "- Plateformes : PC, macOS, Linux, PS4, PS5, Xbox One, Xbox Series, Switch et Switch 2.",
        "- `total_rating_count >= 1`, jaquette et date obligatoires.",
        "- `version_parent = null`, `parent_game = null`.",
        "- Types IGDB : 0, 4, 8, 9, 10.",
        "- Pagination par identifiant, lots de 500, pause de 0,34 s (~2,94 req/s).", "",
        "## Répartition par plateforme", "",
        "| Plateforme | Fiches |", "|---|---:|",
    ]
    lines += [f"| {name} | {count} |" for name, count in sorted(platforms.items(), key=lambda x: (-x[1], x[0]))]
    lines += ["", "Une fiche multiplateforme est comptée dans chaque plateforme.", "", "## Répartition par année", "", "| Année | Fiches |", "|---:|---:|"]
    lines += [f"| {year} | {years[year]} |" for year in sorted(years)]
    lines += ["", "## Incidents et remarques", ""]
    if error:
        lines.append(f"- **Blocage :** {error}")
    lines += [f"- {item}" for item in incidents] or ["- Aucun incident."]
    REPORT_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    existing_keys, existing_ids, existing_records = load_existing()
    print(f"Existant: {existing_records} fiches, {len(existing_ids)} IGDB ID uniques")
    incidents, result = [], {}
    raw = rejected = 0
    try:
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        token = get_token(cfg, incidents)
        fields = ("id,name,slug,first_release_date,aggregated_rating,total_rating,total_rating_count,"
                  "platforms.name,genres.name,themes.name,cover.image_id,"
                  "involved_companies.developer,involved_companies.company.name,"
                  "external_games.category,external_games.uid")
        last_id = 0
        while True:
            where = (f"id > {last_id} & total_rating_count >= 1 & cover != null & "
                     f"first_release_date >= {START_TS} & first_release_date <= {END_TS} & "
                     f"version_parent = null & parent_game = null & game_type = ({','.join(map(str, ALLOWED_TYPES))}) & "
                     f"platforms = ({','.join(map(str, PLATFORM_IDS))})")
            batch = api("games", f"fields {fields}; where {where}; sort id asc; limit {PAGE};",
                        token, cfg["client_id"], incidents)
            raw += len(batch)
            for game in batch:
                gid = int(game["id"])
                if gid in existing_ids or f"igdb:{gid}" in existing_keys:
                    rejected += 1
                else:
                    result[f"igdb:{gid}"] = card(game)
            print(f"Bruts: {raw}; doublons: {rejected}; nouveaux: {len(result)}")
            if len(batch) < PAGE:
                break
            last_id = int(batch[-1]["id"])
            time.sleep(PAUSE)
        atomic_json(OUT_FILE, result)
        if PARTIAL_FILE.exists():
            PARTIAL_FILE.unlink()
        report(existing_records, existing_keys, existing_ids, raw, rejected, result, incidents)
        print(f"Terminé: {OUT_FILE} ({len(result)} fiches)")
    except Exception as exc:
        atomic_json(PARTIAL_FILE, result)
        report(existing_records, existing_keys, existing_ids, raw, rejected, result, incidents,
               partial=True, error=str(exc))
        print(f"BLOCAGE: {exc}", file=sys.stderr)
        print(f"Partiel écrit: {PARTIAL_FILE}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
