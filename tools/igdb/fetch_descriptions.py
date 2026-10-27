#!/usr/bin/env python3
"""Collecte les summaries IGDB des 12 sources Ludodex. Relançable sans redemande.

Depuis la racine Ludodex : python outils_igdb/fetch_descriptions.py
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "outils_igdb/config.json"
TOKEN = ROOT / "outils_igdb/token.json"
OUT_DIR = ROOT / "data/volumes/descriptions_en_2026"
OUT = OUT_DIR / "descriptions_en_2026.json"
REPORT = OUT_DIR / "RAPPORT_DESCRIPTIONS_EN_2026.md"
CHECKPOINT = OUT_DIR / ".checkpoint"
PAGE, PAUSE, RETRIES = 500, .34, 8
SOURCES = (
    "data/volumes/igdb_massif_14663/ludodex_igdb_massif.json",
    "data/volumes/volume_2/ludodex_volume_2.json",
    "data/ludodex_catalogue.json",
    "data/volumes/igdb_volume_3_10015/ludodex_igdb_volume_3.json",
    "data/volumes/igdb_recent_2020_2026/ludodex_igdb_recent_2020_2026.json",
    "data/volumes/igdb_recent_2020_2026_2/ludodex_igdb_recent_2020_2026_2.json",
    "data/volumes/igdb_gamecube_ds_psp/ludodex_igdb_gamecube_ds_psp.json",
    "data/volumes/igdb_ps2_wii_3ds_vita_dreamcast_gba/ludodex_igdb_ps2_wii_3ds_vita_dreamcast_gba.json",
    "data/volumes/igdb_ps3_ps4_x360_xone_wiiu_switch/ludodex_igdb_ps3_ps4_x360_xone_wiiu_switch.json",
    "data/volumes/igdb_modern_rare/ludodex_igdb_modern_rare.json",
    "data/volumes/igdb_modern_2026/ludodex_igdb_modern_2026.json",
    "data/volumes/igdb_exhaustif_2026/ludodex_igdb_exhaustif_2026.json",
)

def load(path, default=None):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default

def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)

def catalogue_ids():
    merged = {}
    for rel in SOURCES:  # même ordre, donc même règle « dernière clé gagnante » que le JS
        path = ROOT / rel
        if not path.exists(): raise FileNotFoundError(f"Source absente : {path}")
        data = load(path)
        if not isinstance(data, dict): raise RuntimeError(f"Objet JSON attendu : {path}")
        merged.update(data)
    ids = set()
    for key, card in merged.items():
        value = card.get("igdb_id") if isinstance(card, dict) else None
        if value is None and isinstance(key, str) and key.startswith("igdb:"): value = key[5:]
        try:
            value = int(value)
            if value > 0: ids.add(value)
        except (TypeError, ValueError): pass
    return sorted(ids), len(merged)

def credentials():
    cfg = load(CONFIG, {})
    if not cfg.get("client_id") or not cfg.get("client_secret"):
        raise RuntimeError(f"Renseigner client_id et client_secret dans {CONFIG}")
    saved = load(TOKEN, {})
    if saved.get("access_token") and saved.get("expires_at", 0) > time.time() + 3600:
        return cfg["client_id"], saved["access_token"]
    query = urllib.parse.urlencode({"client_id": cfg["client_id"],
        "client_secret": cfg["client_secret"], "grant_type": "client_credentials"})
    request = urllib.request.Request(f"https://id.twitch.tv/oauth2/token?{query}", method="POST")
    with urllib.request.urlopen(request, timeout=30) as response: payload = json.load(response)
    atomic(TOKEN, {"access_token": payload["access_token"],
                   "expires_at": time.time() + payload.get("expires_in", 0)})
    return cfg["client_id"], payload["access_token"]

class Client:
    def __init__(self, client_id, token):
        self.client_id, self.token, self.last = client_id, token, 0.0
    def fetch(self, ids):
        delay = PAUSE - (time.monotonic() - self.last)
        if delay > 0: time.sleep(delay)
        body = f"fields id,summary; where id = ({','.join(map(str, ids))}); limit 500;"
        for attempt in range(1, RETRIES + 1):
            req = urllib.request.Request("https://api.igdb.com/v4/games", data=body.encode(),
                method="POST", headers={"Client-ID": self.client_id,
                "Authorization": f"Bearer {self.token}", "Accept": "application/json"})
            try:
                self.last = time.monotonic()
                with urllib.request.urlopen(req, timeout=60) as response: return json.load(response)
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:500]
                if exc.code != 429 or attempt == RETRIES:
                    raise RuntimeError(f"IGDB HTTP {exc.code}: {detail}") from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                if attempt == RETRIES: raise RuntimeError(f"Réseau IGDB : {exc}") from exc
            time.sleep(min(30, attempt * 2))

def resume():
    descriptions, done = load(OUT, {}), set()
    if not isinstance(descriptions, dict): raise RuntimeError(f"Objet JSON attendu : {OUT}")
    if CHECKPOINT.exists():
        for path in sorted(CHECKPOINT.glob("lot_*.json")):
            batch = load(path)
            if not isinstance(batch, dict) or not isinstance(batch.get("processed_ids"), list):
                raise RuntimeError(f"Checkpoint invalide : {path}")
            done.update(map(int, batch["processed_ids"]))
            descriptions.update(batch.get("descriptions", {}))
    return descriptions, done

def report(records, ids, descriptions, started, complete):
    lengths = list(map(len, descriptions.values()))
    missing = len(ids) - len(descriptions) if complete else "calculé à la fin"
    lines = ["# Rapport — descriptions anglaises IGDB 2026", "",
        f"Statut : **{'TERMINÉ' if complete else 'PARTIEL — reprise possible'}**", "",
        f"- Fiches fusionnées : **{records:,}**".replace(",", " "),
        f"- ID IGDB uniques : **{len(ids):,}**".replace(",", " "),
        f"- Jeux avec summary : **{len(descriptions):,}**".replace(",", " "),
        f"- Jeux sans summary : **{missing if isinstance(missing, str) else f'{missing:,}'.replace(',', ' ')}**",
        f"- Taille moyenne : **{sum(lengths)/len(lengths) if lengths else 0:.1f} caractères**",
        f"- Durée de cette exécution : **{(time.monotonic()-started)/60:.1f} min**", "",
        "Aucun résumé absent n'est inventé."]
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")

def main():
    started = time.monotonic(); OUT_DIR.mkdir(parents=True, exist_ok=True); CHECKPOINT.mkdir(exist_ok=True)
    ids, records = catalogue_ids(); descriptions, done = resume()
    remaining = [gid for gid in ids if gid not in done]
    print(f"{records} fiches, {len(ids)} ID; reprise {len(done)}, reste {len(remaining)}")
    try:
        client_id, token = credentials(); client = Client(client_id, token)
        batches = (len(remaining) + PAGE - 1) // PAGE
        for number, offset in enumerate(range(0, len(remaining), PAGE), 1):
            batch_ids = remaining[offset:offset+PAGE]; found = {}
            for game in client.fetch(batch_ids):
                text = game.get("summary")
                if isinstance(text, str) and text.strip(): found[f"igdb:{int(game['id'])}"] = text.strip()
            # Un fichier par lot rend également persistants les ID sans summary.
            atomic(CHECKPOINT / f"lot_{batch_ids[0]:09d}_{batch_ids[-1]:09d}.json",
                   {"processed_ids": batch_ids, "descriptions": found})
            done.update(batch_ids); descriptions.update(found)
            print(f"Lot {number}/{batches}: {len(done)}/{len(ids)}, {len(descriptions)} summaries")
        ordered = dict(sorted(descriptions.items(), key=lambda item: int(item[0][5:])))
        atomic(OUT, ordered); report(records, ids, ordered, started, True)
        print(f"Terminé : {OUT}"); return 0
    except KeyboardInterrupt: print("Interruption; checkpoints conservés.", file=sys.stderr)
    except Exception as exc: print(f"BLOCAGE : {exc}", file=sys.stderr)
    report(records, ids, descriptions, started, False); return 2

if __name__ == "__main__": raise SystemExit(main())
