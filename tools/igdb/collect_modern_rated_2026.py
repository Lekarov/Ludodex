#!/usr/bin/env python3
"""Collecte un gros volume de jeux modernes notes, toutes notes confondues.

Utilisation (depuis la racine de Ludodex) :
    python outils_igdb/collect_modern_rated_2026.py

Le script charge les sources declarees par generate_card_catalogue.js, valide les
plateformes, compte les candidats via /games/count, puis demande confirmation.
Un checkpoint est ecrit apres chaque page : relancer la meme commande reprend la
collecte sans repartir du debut. Bibliotheque standard Python uniquement.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = ROOT / "outils_igdb" / "config.json"
TOKEN_FILE = ROOT / "outils_igdb" / "token.json"
CATALOGUE_GENERATOR = ROOT / "Ludodex Online" / "schema" / "catalogue_import" / "generate_card_catalogue.js"
OUT_DIR = ROOT / "data" / "volumes" / "igdb_modern_rated_2026"
OUT_FILE = OUT_DIR / "ludodex_igdb_modern_rated_2026.json"
PARTIAL_FILE = OUT_DIR / "ludodex_igdb_modern_rated_2026_PARTIEL.json"
STATE_FILE = OUT_DIR / "etat_collecte.json"
REPORT_FILE = OUT_DIR / "RAPPORT_IGDB_MODERN_RATED_2026.md"
MODERN_2026_FILE = ROOT / "data" / "volumes" / "igdb_modern_2026" / "ludodex_igdb_modern_2026.json"

PAGE_SIZE = 500
REQUEST_PAUSE = 0.34                 # ~2,94 requetes/s, sous la limite IGDB de 4/s
MAX_RETRIES = 8
ADDED_AT = "2026-09-27"
START_TS = int(datetime(2011, 1, 1, tzinfo=timezone.utc).timestamp())
END_TS = int(datetime(2026, 9, 27, 23, 59, 59, tzinfo=timezone.utc).timestamp())
ALLOWED_GAME_TYPES = (0, 4, 8, 9, 10)

# Selection volontairement large des plateformes pertinentes pour les sorties modernes.
# Les noms attendus sont controles via /v4/platforms avant tout comptage/telechargement.
PLATFORMS = {
    3: "Linux",
    5: "Wii",
    6: "PC (Microsoft Windows)",
    9: "PlayStation 3",
    12: "Xbox 360",
    14: "Mac",
    34: "Android",
    37: "Nintendo 3DS",
    38: "PlayStation Portable",
    39: "iOS",
    41: "Wii U",
    46: "PlayStation Vita",
    48: "PlayStation 4",
    49: "Xbox One",
    55: "Legacy Mobile Device",
    73: "BlackBerry OS",
    74: "Windows Phone",
    82: "Web browser",
    113: "OnLive Game System",
    121: "Samsung Gear VR",
    130: "Nintendo Switch",
    137: "New Nintendo 3DS",
    161: "Windows Mixed Reality",
    163: "SteamVR",
    164: "Daydream",
    165: "PlayStation VR",
    167: "PlayStation 5",
    169: "Xbox Series X|S",
    170: "Google Stadia",
    384: "Oculus Quest",
    386: "Meta Quest 2",
    390: "PlayStation VR2",
    471: "Meta Quest 3",
    472: "visionOS",
    508: "Nintendo Switch 2",
}
PLATFORM_IDS = tuple(PLATFORMS)

FIELDS = (
    "id,name,slug,first_release_date,aggregated_rating,total_rating,total_rating_count,"
    "platforms.name,genres.name,themes.name,cover.image_id,"
    "involved_companies.developer,involved_companies.company.name,"
    "external_games.category,external_games.uid"
)

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def year_from_timestamp(ts):
    """Evite datetime.fromtimestamp(), non fiable sous Windows hors plage CRT."""
    return (EPOCH + timedelta(seconds=ts)).year


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_json(path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def catalogue_source_paths():
    """Lit CATALOGUE_SOURCES dans le generateur, qui reste l'unique source de verite."""
    text = CATALOGUE_GENERATOR.read_text(encoding="utf-8")
    match = re.search(r"const\s+CATALOGUE_SOURCES\s*=\s*\[(.*?)\];", text, re.DOTALL)
    if not match:
        raise RuntimeError(f"CATALOGUE_SOURCES introuvable dans {CATALOGUE_GENERATOR}.")
    relatives = re.findall(r'["\']([^"\']+\.json)["\']', match.group(1))
    if not relatives:
        raise RuntimeError(f"CATALOGUE_SOURCES est vide dans {CATALOGUE_GENERATOR}.")
    paths = [ROOT / "data" / relative for relative in relatives]
    if MODERN_2026_FILE not in paths:
        paths.append(MODERN_2026_FILE)
    return paths


def extract_keys_and_ids(data, source):
    if not isinstance(data, dict):
        raise RuntimeError(f"Format inattendu dans {source} (objet JSON attendu).")
    keys, ids = set(data), set()
    for key, value in data.items():
        if isinstance(key, str) and key.startswith("igdb:"):
            try:
                ids.add(int(key.split(":", 1)[1]))
            except ValueError:
                pass
        candidate = value.get("igdb_id") if isinstance(value, dict) else None
        try:
            ids.add(int(candidate))
        except (TypeError, ValueError):
            pass
    return keys, ids


def load_existing():
    keys, ids, records = set(), set(), 0
    paths = catalogue_source_paths()
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f"Source catalogue requise introuvable : {path}")
        data = load_json(path)
        records += len(data)
        source_keys, source_ids = extract_keys_and_ids(data, path)
        keys.update(source_keys)
        ids.update(source_ids)
    return keys, ids, records, paths


def load_config():
    cfg = load_json(CONFIG_FILE)
    if not isinstance(cfg, dict) or not cfg.get("client_id") or not cfg.get("client_secret"):
        raise RuntimeError(f"Renseigner client_id et client_secret dans {CONFIG_FILE}.")
    return cfg


def get_token(cfg, incidents):
    saved = load_json(TOKEN_FILE, {})
    if saved.get("expires_at", 0) > time.time() + 3600 and saved.get("access_token"):
        return saved["access_token"]
    params = urllib.parse.urlencode({
        "client_id": cfg["client_id"],
        "client_secret": cfg["client_secret"],
        "grant_type": "client_credentials",
    })
    request = urllib.request.Request(
        f"https://id.twitch.tv/oauth2/token?{params}", method="POST"
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    atomic_json(TOKEN_FILE, {
        "access_token": payload["access_token"],
        "expires_at": time.time() + payload.get("expires_in", 0),
    })
    incidents.append("Un nouveau jeton Twitch a ete genere.")
    return payload["access_token"]


class IgdbClient:
    def __init__(self, client_id, token, incidents):
        self.client_id = client_id
        self.token = token
        self.incidents = incidents
        self.last_request_at = 0.0

    def request(self, endpoint, body):
        delay = REQUEST_PAUSE - (time.monotonic() - self.last_request_at)
        if delay > 0:
            time.sleep(delay)
        for attempt in range(1, MAX_RETRIES + 1):
            request = urllib.request.Request(
                f"https://api.igdb.com/v4/{endpoint}",
                data=body.encode("utf-8"), method="POST",
                headers={
                    "Client-ID": self.client_id,
                    "Authorization": f"Bearer {self.token}",
                    "Accept": "application/json",
                },
            )
            try:
                self.last_request_at = time.monotonic()
                with urllib.request.urlopen(request, timeout=60) as response:
                    return json.load(response)
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:500]
                if exc.code != 429:
                    raise RuntimeError(f"IGDB /{endpoint} : HTTP {exc.code} - {detail}") from exc
                wait = min(30, 1.5 * attempt)
                self.incidents.append(
                    f"HTTP 429 sur /{endpoint}, tentative {attempt}/{MAX_RETRIES}; attente {wait:.1f} s."
                )
                time.sleep(wait)
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                if attempt == MAX_RETRIES:
                    raise RuntimeError(f"Reseau IGDB indisponible apres {MAX_RETRIES} essais : {exc}") from exc
                wait = min(30, 2 * attempt)
                self.incidents.append(
                    f"Erreur reseau temporaire sur /{endpoint} ({exc}); attente {wait} s."
                )
                time.sleep(wait)
        raise RuntimeError(f"IGDB /{endpoint} : echec apres {MAX_RETRIES} tentatives.")

    def count(self, where):
        payload = self.request("games/count", f"where {where};")
        return int(payload.get("count", 0))


def common_where(last_id=None):
    clauses = []
    if last_id is not None:
        clauses.append(f"id > {last_id}")
    clauses.extend([
        "total_rating_count >= 1",
        "cover != null",
        "first_release_date != null",
        f"first_release_date >= {START_TS}",
        f"first_release_date <= {END_TS}",
        "version_parent = null",
        "parent_game = null",
        f"game_type = ({','.join(map(str, ALLOWED_GAME_TYPES))})",
        f"platforms = ({','.join(map(str, PLATFORM_IDS))})",
    ])
    return " & ".join(clauses)


def validate_platforms(client, incidents):
    body = f"fields id,name; where id = ({','.join(map(str, PLATFORM_IDS))}); limit 500;"
    found = {int(item["id"]): item.get("name", "") for item in client.request("platforms", body)}
    missing = [platform_id for platform_id in PLATFORM_IDS if platform_id not in found]
    mismatched = [
        (platform_id, PLATFORMS[platform_id], found[platform_id])
        for platform_id in PLATFORM_IDS
        if platform_id in found and found[platform_id] != PLATFORMS[platform_id]
    ]
    if missing:
        raise RuntimeError("IDs de plateformes absents d'IGDB : " + ", ".join(map(str, missing)))
    if mismatched:
        incidents.append("Noms de plateformes actualises par IGDB : " + "; ".join(
            f"{pid} {expected!r} -> {actual!r}" for pid, expected, actual in mismatched
        ))
    return found


def developer(game):
    for company in game.get("involved_companies") or []:
        if company.get("developer") and company.get("company", {}).get("name"):
            return company["company"]["name"]
    return "Inconnu"


def steam_appid(game):
    for external in game.get("external_games") or []:
        uid = str(external.get("uid", ""))
        if external.get("category") == 1 and uid.isdigit():
            return int(uid)
    return None


def card(game):
    game_id = int(game["id"])
    image_id = game["cover"]["image_id"]
    rating = game.get("aggregated_rating") or game.get("total_rating")
    return {
        "id": f"igdb:{game_id}",
        "igdb_id": game_id,
        "steam_appid": steam_appid(game),
        "title": game["name"],
        "year": year_from_timestamp(game["first_release_date"]),
        "developer": developer(game),
        "platforms": sorted({p["name"] for p in game.get("platforms", []) if p.get("name")}),
        "genres": [item["name"] for item in game.get("genres", []) if item.get("name")],
        "themes": [item["name"] for item in game.get("themes", []) if item.get("name")],
        "cover": {
            "url": f"https://images.igdb.com/igdb/image/upload/t_cover_big/{image_id}.jpg",
            "square_url": f"https://images.igdb.com/igdb/image/upload/t_thumb/{image_id}.jpg",
            "source": "igdb",
            "image_id": image_id,
        },
        "source_page": f"https://www.igdb.com/games/{game.get('slug', '')}",
        "verification_status": "verified",
        "duplicate_of": None,
        "merged_from": [f"igdb:games:{game_id}"],
        "conflict_fields": [],
        "last_updated_source": f"igdb:games:{game_id}",
        "added_at": ADDED_AT,
        "selection": {
            "rating": round(rating, 2) if rating is not None else None,
            "rating_count": game["total_rating_count"],
            "minimum_rating_count": 1,
        },
    }


def fmt(number):
    return f"{int(number):,}".replace(",", " ")


def initial_state():
    return {"version": 1, "status": "pending", "last_id": 0, "candidate_count": None,
            "raw": 0, "rejected": 0, "invalid": 0}


def save_checkpoint(cards, state):
    atomic_json(PARTIAL_FILE, cards)
    state["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    atomic_json(STATE_FILE, state)


def write_report(state, cards, sources, existing_records, existing_keys, existing_ids,
                 platform_names, incidents, status, error=None):
    years = Counter(str(value["year"]) for value in cards.values())
    platforms = Counter(p for value in cards.values() for p in value.get("platforms", []))
    lines = [
        "# Rapport - volume IGDB moderne note 2026", "",
        f"Statut : **{status}**", "",
        "## Resultat", "",
        f"- Sources catalogue chargees : **{fmt(len(sources))}**",
        f"- Fiches inspectees dans ces sources : **{fmt(existing_records)}**",
        f"- Cles existantes : **{fmt(len(existing_keys))}**",
        f"- Identifiants IGDB existants uniques : **{fmt(len(existing_ids))}**",
        f"- Candidats bruts annonces par `games/count` : **{fmt(state.get('candidate_count') or 0)}**",
        f"- Candidats bruts parcourus : **{fmt(state.get('raw') or 0)}**",
        f"- Rejetes car deja presents : **{fmt(state.get('rejected') or 0)}**",
        f"- Fiches invalides ignorees : **{fmt(state.get('invalid') or 0)}**",
        f"- Fiches finales ecrites : **{fmt(len(cards))}**", "",
        "## Perimetre et choix", "",
        "- Dates de sortie : du 1er janvier 2011 au 27 septembre 2026 inclus.",
        "- La date de debut reste 2011 : les annees anterieures relevent surtout du retro et sont deja couvertes par plusieurs volumes; le trou vise ici est celui des jeux modernes notes.",
        "- Toute la gamme de notes est admise : seul `total_rating_count >= 1` est exige, sans seuil de note.",
        "- Jaquette et date obligatoires; `version_parent = null`; `parent_game = null`; types IGDB 0, 4, 8, 9 et 10.",
        "- Plateformes etendues aux PC, consoles actives ou encore pertinentes depuis 2011, mobiles, navigateur, VR et cloud.",
        "- Un jeu multiplateforme correspondant a plusieurs IDs n'est renvoye qu'une fois : il n'y a qu'un lot, donc aucun chevauchement entre lots.",
        "- Pagination par identifiant, pages de 500, pause de 0,34 s (~2,94 requetes/s).", "",
        "## Plateformes selectionnees", "",
        "| ID IGDB | Plateforme | Groupe |", "|---:|---|---|",
    ]
    console_ids = {5, 9, 12, 37, 38, 41, 46, 48, 49, 130, 137, 167, 169, 508}
    mobile_ids = {34, 39, 55, 73, 74}
    vr_ids = {121, 161, 163, 164, 165, 384, 386, 390, 471, 472}
    cloud_ids = {113, 170}
    for platform_id in PLATFORM_IDS:
        group = ("Console" if platform_id in console_ids else
                 "Mobile" if platform_id in mobile_ids else
                 "VR" if platform_id in vr_ids else
                 "Cloud" if platform_id in cloud_ids else
                 "Web" if platform_id == 82 else "PC")
        lines.append(f"| {platform_id} | {platform_names.get(platform_id, PLATFORMS[platform_id])} | {group} |")
    lines += ["", "## Repartition par plateforme", "", "| Plateforme | Fiches |", "|---|---:|"]
    lines += [f"| {name} | {fmt(count)} |" for name, count in platforms.most_common()]
    lines += ["", "Une fiche multiplateforme est comptee dans chaque plateforme.", "",
              "## Repartition par annee", "", "| Annee | Fiches |", "|---:|---:|"]
    lines += [f"| {year} | {fmt(years[year])} |" for year in sorted(years)]
    lines += ["", "## Incidents et remarques", ""]
    if error:
        lines.append(f"- **Interruption :** {error}")
    lines += [f"- {item}" for item in incidents] or ["- Aucun incident."]
    REPORT_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUT_FILE.exists() and not STATE_FILE.exists() and not PARTIAL_FILE.exists():
        print(f"Collecte deja terminee : {OUT_FILE}")
        return 0
    incidents = []
    existing_keys, existing_ids, existing_records, sources = load_existing()
    catalogue_keys = set(existing_keys)
    catalogue_ids = set(existing_ids)
    print(f"Sources chargees : {fmt(existing_records)} fiches; {fmt(len(existing_ids))} IGDB ID uniques.")

    state = load_json(STATE_FILE, initial_state())
    if not isinstance(state, dict) or state.get("version") != 1:
        raise RuntimeError(f"Etat de reprise incompatible : {STATE_FILE}")
    result = load_json(PARTIAL_FILE, {})
    if not isinstance(result, dict):
        raise RuntimeError(f"Format de reprise invalide : {PARTIAL_FILE}")
    partial_keys, partial_ids = extract_keys_and_ids(result, PARTIAL_FILE)
    existing_keys.update(partial_keys)
    existing_ids.update(partial_ids)

    cfg = load_config()
    token = get_token(cfg, incidents)
    client = IgdbClient(cfg["client_id"], token, incidents)
    platform_names = {}

    try:
        platform_names = validate_platforms(client, incidents)
        if state.get("status") == "completed" and OUT_FILE.exists():
            print(f"Collecte deja terminee : {OUT_FILE}")
            return 0

        print("Precomptage IGDB (aucune fiche de jeu n'est encore telechargee)...")
        candidate_count = client.count(common_where())
        state["candidate_count"] = candidate_count
        state["status"] = "awaiting_confirmation"
        save_checkpoint(result, state)
        remaining_estimate = max(0, candidate_count - int(state.get("raw", 0)))
        print(f"Candidats bruts IGDB : {fmt(candidate_count)} au total; environ {fmt(remaining_estimate)} restent a parcourir.")
        print("Un jeu present sur plusieurs plateformes ne compte qu'une fois; ce lot unique ne se chevauche pas avec lui-meme.")
        answer = input(f"Environ {fmt(remaining_estimate)} jeux vont etre parcourus, continuer ? (o/n) ").strip().lower()
        if answer not in {"o", "oui"}:
            write_report(state, result, sources, existing_records, catalogue_keys,
                         catalogue_ids, platform_names, incidents, "EN ATTENTE DE CONFIRMATION")
            print("Collecte annulee : aucune nouvelle fiche de jeu n'a ete telechargee.")
            return 0

        state["status"] = "running"
        last_id = int(state.get("last_id", 0))
        while True:
            body = f"fields {FIELDS}; where {common_where(last_id)}; sort id asc; limit {PAGE_SIZE};"
            batch = client.request("games", body)
            state["raw"] = int(state.get("raw", 0)) + len(batch)
            for game in batch:
                try:
                    game_id = int(game["id"])
                    key = f"igdb:{game_id}"
                    if game_id in existing_ids or key in existing_keys:
                        state["rejected"] = int(state.get("rejected", 0)) + 1
                    elif (game.get("total_rating_count") or 0) < 1:
                        state["invalid"] = int(state.get("invalid", 0)) + 1
                    else:
                        result[key] = card(game)
                        existing_ids.add(game_id)
                        existing_keys.add(key)
                except (KeyError, TypeError, ValueError, OverflowError, OSError) as exc:
                    state["invalid"] = int(state.get("invalid", 0)) + 1
                    incidents.append(f"Fiche {game.get('id', '?')} invalide ignoree ({exc}).")
            if batch:
                last_id = int(batch[-1]["id"])
                state["last_id"] = last_id
            save_checkpoint(result, state)
            print(f"\rBruts {fmt(state['raw'])} | rejetes {fmt(state['rejected'])} | nouveaux {fmt(len(result))}",
                  end="", flush=True)
            if len(batch) < PAGE_SIZE:
                break

        atomic_json(OUT_FILE, result)
        state["status"] = "completed"
        state["completed_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        write_report(state, result, sources, existing_records, catalogue_keys,
                     catalogue_ids, platform_names,
                     incidents, "TERMINE")
        if PARTIAL_FILE.exists():
            PARTIAL_FILE.unlink()
        if STATE_FILE.exists():
            STATE_FILE.unlink()
        print(f"\nCollecte terminee : {OUT_FILE} ({fmt(len(result))} fiches)")
        print(f"Rapport : {REPORT_FILE}")
        return 0
    except KeyboardInterrupt:
        error = "Interruption demandee au clavier (Ctrl+C). La reprise utilisera le dernier checkpoint."
        state["status"] = "interrupted"
        save_checkpoint(result, state)
        write_report(state, result, sources, existing_records, catalogue_keys,
                     catalogue_ids, platform_names or PLATFORMS,
                     incidents, "INTERROMPU", error)
        print(f"\n{error}", file=sys.stderr)
        return 130
    except Exception as exc:
        error = str(exc)
        incidents.append(error)
        state["status"] = "interrupted"
        save_checkpoint(result, state)
        write_report(state, result, sources, existing_records, catalogue_keys,
                     catalogue_ids, platform_names or PLATFORMS,
                     incidents, "INTERROMPU", error)
        print(f"\nBLOCAGE : {error}", file=sys.stderr)
        print(f"Partiel ecrit : {PARTIAL_FILE}. Relancer la meme commande pour reprendre.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
