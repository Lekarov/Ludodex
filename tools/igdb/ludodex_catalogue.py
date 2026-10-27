#!/usr/bin/env python3
"""
Ludodex : télécharge le catalogue de jeux depuis IGDB et génère catalogue.json.

Utilisation : placer ce fichier et config.json dans le même dossier, puis lancer
    python ludodex_catalogue.py

Aucune installation supplémentaire : uniquement la bibliothèque standard de Python.
"""
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG = HERE / "config.json"
TOKEN_FILE = HERE / "token.json"
OUT = HERE / "catalogue.json"

MIN_RATINGS = 5   # nombre minimal d'avis pour qu'un jeu devienne une carte
PAGE = 500        # maximum autorisé par IGDB par requête
PAUSE = 0.3       # environ 3 requêtes par seconde, sous la limite de 4


def load_config():
    if not CONFIG.exists():
        sys.exit(f"Fichier introuvable : {CONFIG.name}. Place-le à côté du script.")
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    if not cfg.get("client_id") or "COLLE" in cfg.get("client_secret", "COLLE"):
        sys.exit("Renseigne client_id et client_secret dans config.json.")
    return cfg


def get_token(cfg):
    """Récupère un jeton d'accès Twitch, réutilisé tant qu'il est valide."""
    if TOKEN_FILE.exists():
        saved = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        if saved.get("expires_at", 0) > time.time() + 3600:
            return saved["access_token"]
    params = urllib.parse.urlencode({
        "client_id": cfg["client_id"],
        "client_secret": cfg["client_secret"],
        "grant_type": "client_credentials",
    })
    req = urllib.request.Request(f"https://id.twitch.tv/oauth2/token?{params}", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"Connexion à Twitch refusée ({e.code}). Vérifie client_id et client_secret.")
    TOKEN_FILE.write_text(json.dumps({
        "access_token": data["access_token"],
        "expires_at": time.time() + data.get("expires_in", 0),
    }), encoding="utf-8")
    print("Jeton d'accès obtenu.")
    return data["access_token"]


def igdb(endpoint, body, token, client_id):
    req = urllib.request.Request(
        f"https://api.igdb.com/v4/{endpoint}",
        data=body.encode("utf-8"),
        method="POST",
        headers={
            "Client-ID": client_id,
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
    )
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:            # trop de requêtes : on patiente
                time.sleep(1 + attempt)
                continue
            detail = e.read().decode("utf-8", "replace")[:300]
            raise RuntimeError(f"IGDB {endpoint} : erreur {e.code} {detail}")
    raise RuntimeError(f"IGDB {endpoint} : limite de requêtes dépassée trop souvent.")


def fetch_all(endpoint, fields, where, token, client_id, label):
    """Parcourt toute une table IGDB par lots de 500, triés par identifiant."""
    rows, last_id = [], 0
    while True:
        cond = f"id > {last_id}" + (f" & {where}" if where else "")
        body = f"fields {fields}; where {cond}; sort id asc; limit {PAGE};"
        batch = igdb(endpoint, body, token, client_id)
        rows.extend(batch)
        print(f"\r{label} : {len(rows)} récupérés", end="", flush=True)
        if len(batch) < PAGE:
            break
        last_id = batch[-1]["id"]
        time.sleep(PAUSE)
    print()
    return rows


def main():
    cfg = load_config()
    token = get_token(cfg)
    cid = cfg["client_id"]

    games = fetch_all(
        "games",
        "name,first_release_date,aggregated_rating,total_rating,total_rating_count,"
        "platforms.name,involved_companies.developer,involved_companies.company.name",
        f"total_rating_count >= {MIN_RATINGS} & version_parent = null & parent_game = null",
        token, cid, "Jeux",
    )

    ttb = {}
    try:
        for row in fetch_all("game_time_to_beats", "game_id,normally,hastily",
                             "", token, cid, "Durées de vie"):
            sec = row.get("normally") or row.get("hastily")
            if row.get("game_id") and sec:
                ttb[row["game_id"]] = sec
    except RuntimeError as e:
        print(f"Durées de vie indisponibles, valeur par défaut utilisée. ({e})")

    max_count = max((g.get("total_rating_count", 0) for g in games), default=1)
    cards = []
    for g in games:
        rating = g.get("aggregated_rating") or g.get("total_rating")
        date = g.get("first_release_date")
        if not rating or not date or not g.get("name"):
            continue
        companies = g.get("involved_companies") or []
        dev = next((c["company"]["name"] for c in companies
                    if c.get("developer") and c.get("company")), None)
        if not dev and companies and companies[0].get("company"):
            dev = companies[0]["company"]["name"]
        platforms = g.get("platforms") or []
        count = g.get("total_rating_count", 0)
        cards.append({
            "id": g["id"],
            "t": g["name"],
            "p": platforms[0]["name"] if platforms else "Inconnue",
            "y": datetime.fromtimestamp(date, tz=timezone.utc).year,
            "d": dev or "Inconnu",
            "c": round(rating),
            "pop": round(100 * math.log1p(count) / math.log1p(max_count)),
            "h": max(1, round(ttb[g["id"]] / 3600)) if g["id"] in ttb else 10,
        })

    OUT.write_text(json.dumps({
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "count": len(cards),
        "games": cards,
    }, ensure_ascii=False), encoding="utf-8")
    print(f"Terminé : {len(cards)} jeux enregistrés dans {OUT.name}.")


if __name__ == "__main__":
    main()
