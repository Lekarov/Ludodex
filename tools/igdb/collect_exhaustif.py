#!/usr/bin/env python3
"""Collecte exhaustive des jeux IGDB sans avis, en un seul passage.

Utilisation (depuis la racine de Ludodex) :
    python outils_igdb/collect_exhaustif.py

Le script commence par compter tous les lots sans télécharger les fiches, affiche
une estimation (les lots spécialisés peuvent se chevaucher), puis demande une
confirmation. Répondre ``o`` lance la collecte; toute autre réponse l'annule.
Les lots terminés ne sont ni retéléchargés ni soumis à une nouvelle confirmation.
Une interruption est sans danger : relancer exactement la même commande reprend
au dernier identifiant sauvegardé. Bibliothèque standard Python uniquement.
"""

import json
import os
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
OUT_DIR = ROOT / "data" / "volumes" / "igdb_exhaustif_2026"
STATE_FILE = OUT_DIR / "etat_collecte.json"
REPORT_FILE = OUT_DIR / "RAPPORT_EXHAUSTIF.md"

PAGE_SIZE = 500
REQUEST_PAUSE = 0.34                 # ~2,94 requêtes/s, sous la limite IGDB de 4/s
MAX_RETRIES = 8
ADDED_AT = "2026-09-27"
END_2026 = int(datetime(2026, 12, 31, 23, 59, 59, tzinfo=timezone.utc).timestamp())
ALLOWED_GAME_TYPES = (0, 4, 8, 9, 10)

# Les 10 sources historiques, puis le volume moderne ajouté le 27/09/2026.
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
    "data/volumes/igdb_modern_2026/ludodex_igdb_modern_2026.json",
)

# Plateformes japonaises/rétro peu représentées dans les volumes précédents.
RETRO_PLATFORM_IDS = (18, 19, 27, 32, 50, 53, 57, 84, 119, 120, 123, 125, 149, 152, 158)
ARCADE_PLATFORM_IDS = (52,)
MOBILE_WEB_PLATFORM_IDS = (34, 39, 82)

FIELDS = (
    "id,name,slug,first_release_date,aggregated_rating,total_rating,total_rating_count,"
    "platforms.name,genres.name,themes.name,cover.image_id,"
    "involved_companies.developer,involved_companies.company.name,"
    "external_games.category,external_games.uid"
)


def timestamp(year, month=1, day=1):
    return int(datetime(year, month, day, tzinfo=timezone.utc).timestamp())


# datetime.fromtimestamp() plante sous Windows ([Errno 22] Invalid argument) pour certains
# timestamps négatifs ou hors plage (le CRT Windows ne les supporte pas, contrairement à Linux) —
# rencontré sur de vraies fiches IGDB (dates arcade mal renseignées, antérieures à 1970). Calcul
# par addition pure Python, sans passer par le C runtime, pour ne jamais planter dessus.
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def year_from_timestamp(ts):
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


def extract_ids(data, source):
    if not isinstance(data, dict):
        raise RuntimeError(f"Format inattendu dans {source} (objet JSON attendu).")
    ids = set()
    for key, value in data.items():
        candidate = value.get("igdb_id") if isinstance(value, dict) else None
        if candidate is None and isinstance(key, str) and key.startswith("igdb:"):
            candidate = key.split(":", 1)[1]
        try:
            ids.add(int(candidate))
        except (TypeError, ValueError):
            pass
    return ids


def load_all_known_ids():
    """Charge les 11 sources et les sorties de reprise une seule fois."""
    known, records = set(), 0
    for relative in EXISTING_FILES:
        path = ROOT / relative
        if not path.exists():
            raise FileNotFoundError(f"Source requise introuvable : {path}")
        data = load_json(path)
        records += len(data)
        known.update(extract_ids(data, relative))

    resumed = 0
    if OUT_DIR.exists():
        for path in sorted(OUT_DIR.glob("*.json")):
            if path == STATE_FILE:
                continue
            data = load_json(path, {})
            ids = extract_ids(data, path.name)
            resumed += len(ids)
            known.update(ids)
    return known, records, resumed


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
    incidents.append("Un nouveau jeton Twitch a été généré.")
    return payload["access_token"]


class IgdbClient:
    def __init__(self, client_id, token, incidents):
        self.client_id = client_id
        self.token = token
        self.incidents = incidents
        self.last_request_at = 0.0

    def request(self, endpoint, body):
        # Le rythme est appliqué à toutes les requêtes, y compris /count et les reprises.
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
                    raise RuntimeError(f"IGDB /{endpoint} : HTTP {exc.code} — {detail}") from exc
                wait = min(30, 1.5 * attempt)
                self.incidents.append(
                    f"HTTP 429 sur /{endpoint}, tentative {attempt}/{MAX_RETRIES}; attente {wait:.1f} s."
                )
                time.sleep(wait)
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                if attempt == MAX_RETRIES:
                    raise RuntimeError(f"Réseau IGDB indisponible après {MAX_RETRIES} essais : {exc}") from exc
                wait = min(30, 2 * attempt)
                self.incidents.append(
                    f"Erreur réseau temporaire sur /{endpoint} ({exc}); attente {wait} s."
                )
                time.sleep(wait)
        raise RuntimeError(f"IGDB /{endpoint} : échec après {MAX_RETRIES} tentatives.")

    def count(self, where):
        payload = self.request("games/count", f"where {where};")
        return int(payload.get("count", 0))


def common_where(extra):
    types = ",".join(map(str, ALLOWED_GAME_TYPES))
    return (
        "(total_rating_count = null | total_rating_count = 0) & cover != null & "
        "first_release_date != null & version_parent = null & parent_game = null & "
        f"game_type = ({types}) & ({extra})"
    )


def dated_range(start_year, end_year):
    start = timestamp(start_year)
    end = timestamp(end_year + 1) - 1
    return f"first_release_date >= {start} & first_release_date <= {end}"


def lot(name, title, extra, upcoming=False, warning=None):
    return {
        "name": name,
        "title": title,
        "where": common_where(extra),
        "upcoming": upcoming,
        "warning": warning,
    }


def build_lots(client):
    """Construit le plan final; 2010–2019 est scindé seulement au-delà de 15 000."""
    decade_2010_where = common_where(dated_range(2010, 2019))
    decade_2010_count = client.count(decade_2010_where)

    # L'ordre donne la priorité absolue aux sorties futures, puis aux catégories
    # spécialisées. Les lots chronologiques récupèrent ensuite tout le reste.
    lots = [
        lot("sorties_futures_apres_2026", "Sorties futures (> 2026)",
            f"first_release_date > {END_2026}", upcoming=True),
        lot("retro_japonais_plateformes_sous_representees",
            "Rétro japonais et plateformes sous-représentées",
            f"first_release_date <= {END_2026} & platforms = ({','.join(map(str, RETRO_PLATFORM_IDS))})"),
        lot("arcade", "Arcade",
            f"first_release_date <= {END_2026} & platforms = ({','.join(map(str, ARCADE_PLATFORM_IDS))})"),
        # Lot "mobile_web" retiré le 27/09/2026 (décision utilisateur) : à zéro avis, ce segment
        # est dominé par du mobile/navigateur ultra-obscur ou abandonné (26 671 candidats bruts
        # au précomptage), peu pertinent pour un TCG de jeux reconnaissables. MOBILE_WEB_PLATFORM_IDS
        # reste défini plus bas si on veut le réactiver un jour.
        lot("avant_1990", "Avant 1990", f"first_release_date < {timestamp(1990)}"),
        lot("1990_1999", "1990–1999", dated_range(1990, 1999)),
        lot("2000_2009", "2000–2009", dated_range(2000, 2009)),
    ]
    if decade_2010_count > 15000:
        lots.extend([
            lot("2010_2014", "2010–2014", dated_range(2010, 2014)),
            lot("2015_2019", "2015–2019", dated_range(2015, 2019)),
        ])
    else:
        lots.append(lot("2010_2019", "2010–2019", dated_range(2010, 2019)))
    lots.append(lot("2020_2026", "2020–2026", dated_range(2020, 2026)))
    return lots, decade_2010_count


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


def make_card(game, upcoming):
    game_id = int(game["id"])
    image_id = game["cover"]["image_id"]
    rating = game.get("aggregated_rating") or game.get("total_rating")
    card = {
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
        "verification_status": "upcoming" if upcoming else "verified",
        "duplicate_of": None,
        "merged_from": [f"igdb:games:{game_id}"],
        "conflict_fields": [],
        "last_updated_source": f"igdb:games:{game_id}",
        "added_at": ADDED_AT,
        "selection": {
            "rating": round(rating, 2) if rating is not None else None,
            "rating_count": game.get("total_rating_count") or 0,
            "minimum_rating_count": 0,
        },
    }
    if upcoming:
        card["release_status"] = "upcoming"
    return card


def default_lot_state():
    return {"status": "pending", "last_id": 0, "raw": 0, "accepted": 0,
            "duplicates": 0, "invalid": 0, "count": None}


def save_state(state):
    state["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    atomic_json(STATE_FILE, state)


def collect_lot(client, spec, known_ids, state, incidents):
    name = spec["name"]
    path = OUT_DIR / f"{name}.json"
    result = load_json(path, {})
    if not isinstance(result, dict):
        raise RuntimeError(f"Format de reprise invalide : {path}")
    progress = state["lots"].setdefault(name, default_lot_state())
    last_id = int(progress.get("last_id", 0))
    progress["status"] = "running"
    save_state(state)

    while True:
        where = f"id > {last_id} & ({spec['where']})"
        body = f"fields {FIELDS}; where {where}; sort id asc; limit {PAGE_SIZE};"
        batch = client.request("games", body)
        progress["raw"] += len(batch)
        for game in batch:
            try:
                game_id = int(game["id"])
                # Défense locale supplémentaire : seules les fiches réellement sans avis passent.
                if (game.get("total_rating_count") or 0) > 0:
                    progress["invalid"] += 1
                elif game_id in known_ids:
                    progress["duplicates"] += 1
                else:
                    result[f"igdb:{game_id}"] = make_card(game, spec["upcoming"])
                    known_ids.add(game_id)  # immédiat : les lots suivants ne le reproposeront pas
                    progress["accepted"] += 1
            except (KeyError, TypeError, ValueError, OverflowError, OSError) as exc:
                progress["invalid"] += 1
                incidents.append(f"{name}: fiche {game.get('id', '?')} invalide ignorée ({exc}).")

        if batch:
            last_id = int(batch[-1]["id"])
            progress["last_id"] = last_id
        # Checkpoint atomique après chaque page : données d'abord, curseur ensuite.
        atomic_json(path, result)
        save_state(state)
        print(
            f"\r{name}: bruts {progress['raw']:,} | acceptés {progress['accepted']:,} | "
            f"doublons {progress['duplicates']:,}", end="", flush=True
        )
        if len(batch) < PAGE_SIZE:
            break

    progress["status"] = "completed"
    progress["completed_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    save_state(state)
    print(f"\nLot terminé : {path} ({len(result):,} fiches)")


def fmt(number):
    return f"{int(number):,}".replace(",", " ")


def write_report(state, lots, existing_records, known_count, resumed, incidents, status, error=None):
    cards_by_lot = {}
    all_cards = {}
    for spec in lots:
        data = load_json(OUT_DIR / f"{spec['name']}.json", {}) or {}
        cards_by_lot[spec["name"]] = data
        all_cards.update(data)
    platforms = Counter(p for card in all_cards.values() for p in card.get("platforms", []))
    years = Counter(str(card.get("year", "Inconnue")) for card in all_cards.values())

    lines = [
        "# Rapport — extraction IGDB exhaustive sans avis", "",
        f"Statut : **{status}**", "",
        "## Mode d'emploi", "",
        "Depuis la racine de Ludodex, lancer : `python outils_igdb\\collect_exhaustif.py`.",
        "Le premier écran ne fait que compter les lots. Répondre `o` au prompt autorise le téléchargement; toute autre réponse annule.",
        "Le total annoncé est une borne haute car les lots spécialisés se chevauchent avec les périodes. En cas d'interruption, relancer la même commande.",
        "Les lots déjà terminés sont automatiquement ignorés.", "",
        "## Résultat global", "",
        f"- Fiches inspectées dans les 11 sources : **{fmt(existing_records)}**",
        f"- Identifiants déjà connus au démarrage : **{fmt(known_count)}**",
        f"- Fiches retrouvées dans une collecte précédente : **{fmt(resumed)}**",
        f"- Fiches exhaustives actuellement écrites : **{fmt(len(all_cards))}**", "",
        "## Lots", "",
        "| Lot | Comptage IGDB | Bruts parcourus | Acceptés | Déjà connus / chevauchements | Invalides | État |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for spec in lots:
        progress = state.get("lots", {}).get(spec["name"], {})
        lines.append(
            f"| {spec['title']} | {fmt(progress.get('count') or 0)} | "
            f"{fmt(progress.get('raw') or 0)} | {fmt(len(cards_by_lot[spec['name']]))} | "
            f"{fmt(progress.get('duplicates') or 0)} | {fmt(progress.get('invalid') or 0)} | "
            f"{progress.get('status', 'pending')} |"
        )
    lines += ["", "## Répartition par plateforme", "", "| Plateforme | Fiches |", "|---|---:|"]
    lines += [f"| {name} | {fmt(count)} |" for name, count in platforms.most_common()]
    lines += ["", "Une fiche multiplateforme est comptée dans chaque plateforme.", "",
              "## Répartition par année", "", "| Année | Fiches |", "|---:|---:|"]
    lines += [f"| {year} | {fmt(years[year])} |" for year in sorted(years)]
    lines += ["", "## Incidents et remarques", ""]
    if error:
        lines.append(f"- **Interruption :** {error}")
    lines += [f"- {item}" for item in incidents] or ["- Aucun incident."]
    REPORT_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    incidents = []
    state = load_json(STATE_FILE, {"version": 1, "lots": {}, "incidents": []})
    if state.get("version") != 1 or not isinstance(state.get("lots"), dict):
        raise RuntimeError(f"État de reprise incompatible : {STATE_FILE}")
    incidents.extend(state.get("incidents", []))

    known_ids, existing_records, resumed = load_all_known_ids()
    known_at_start = len(known_ids)
    print(f"Sources chargées une fois : {fmt(existing_records)} fiches; {fmt(known_at_start)} IGDB ID connus.")

    cfg = load_config()
    token = get_token(cfg, incidents)
    client = IgdbClient(cfg["client_id"], token, incidents)

    try:
        print("\nPrécomptage IGDB de tous les lots (aucune fiche n'est encore téléchargée)…")
        lots, decade_count = build_lots(client)
        print(f"2010–2019 : {fmt(decade_count)} candidats; " +
              ("période scindée en 2010–2014 / 2015–2019." if decade_count > 15000
               else "un seul lot suffit."))

        pending = []
        estimated = 0
        for spec in lots:
            progress = state["lots"].setdefault(spec["name"], default_lot_state())
            if progress.get("status") == "completed":
                print(f"  ✓ {spec['title']}: déjà terminé, ignoré")
                continue
            count = client.count(spec["where"])
            progress["count"] = count
            pending.append(spec)
            estimated += count
            print(f"  - {spec['title']}: {fmt(count)} candidat(s)")
            if spec.get("warning"):
                print(f"    ⚠ {spec['warning']}")
        state["incidents"] = incidents
        save_state(state)

        if not pending:
            write_report(state, lots, existing_records, known_at_start, resumed, incidents, "TERMINÉ")
            print("Tous les lots sont déjà terminés. Rapport actualisé.")
            return 0

        print("\nLes lots spécialisés se chevauchent : le total est une estimation haute; le dédoublonnage est immédiat.")
        answer = input(f"Environ {fmt(estimated)} jeux vont être récupérés, continuer ? (o/n) ").strip().lower()
        if answer not in {"o", "oui"}:
            print("Collecte annulée : aucune fiche de jeu n'a été téléchargée.")
            write_report(state, lots, existing_records, known_at_start, resumed, incidents, "EN ATTENTE DE CONFIRMATION")
            return 0

        for spec in pending:
            print(f"\n=== {spec['title']} ===")
            if spec.get("warning"):
                print(f"⚠ {spec['warning']}")
            collect_lot(client, spec, known_ids, state, incidents)
            state["incidents"] = incidents
            write_report(state, lots, existing_records, known_at_start, resumed, incidents, "EN COURS")

        write_report(state, lots, existing_records, known_at_start, resumed, incidents, "TERMINÉ")
        print(f"\nCollecte terminée. Rapport : {REPORT_FILE}")
        return 0
    except KeyboardInterrupt:
        error = "Interruption demandée au clavier (Ctrl+C). La reprise utilisera le dernier checkpoint."
        incidents.append(error)
        state["incidents"] = incidents
        save_state(state)
        if "lots" in locals():
            write_report(state, lots, existing_records, known_at_start, resumed, incidents, "INTERROMPU", error)
        print(f"\n{error}", file=sys.stderr)
        return 130
    except Exception as exc:
        error = str(exc)
        incidents.append(error)
        state["incidents"] = incidents
        save_state(state)
        if "lots" in locals():
            write_report(state, lots, existing_records, known_at_start, resumed, incidents, "INTERROMPU", error)
        print(f"\nBLOCAGE : {error}", file=sys.stderr)
        print("Relancer la même commande pour reprendre.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
