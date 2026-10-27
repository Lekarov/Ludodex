"""File de progression propre à l'outil : quels jeux ont déjà été passés en revue, où
reprendre avec 'Suivante', et le filtre de plateforme choisi (persisté, pas juste en mémoire
de page, pour ne pas le reperdre entre deux sessions). Écriture atomique comme
overrides_store.py.
"""
import json
import os
import tempfile
from threading import Lock

from config import PROGRESS_FILE
from core.catalogue import ordered_ids

_LOCK = Lock()
_DEFAULT = {"done": {}, "cursor": None, "filter": None}


def _read():
    if not PROGRESS_FILE.exists():
        return dict(_DEFAULT)
    with open(PROGRESS_FILE, encoding="utf-8") as f:
        content = f.read().strip()
        data = json.loads(content) if content else {}
    return {**_DEFAULT, **data}


def _write(data):
    PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=PROGRESS_FILE.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, PROGRESS_FILE)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise


def mark_done(game_id):
    with _LOCK:
        data = _read()
        data["done"][game_id] = True
        data["cursor"] = game_id
        _write(data)


def get_filter():
    with _LOCK:
        return _read().get("filter")


def set_filter(platform):
    with _LOCK:
        data = _read()
        data["filter"] = platform or None
        _write(data)


def stats(platform=None):
    with _LOCK:
        data = _read()
    ids = ordered_ids(platform)
    done_in_scope = sum(1 for i in ids if i in data["done"])
    return {"total": len(ids), "done": done_in_scope, "cursor": data.get("cursor")}


def next_id(after_id=None, platform=None):
    """Premier id non traité, strictement après after_id dans l'ordre stable filtré ; si
    after_id est None reprend juste après le curseur enregistré. Boucle à zéro si on atteint
    la fin (tout redevient 'à faire' pour une deuxième passe seulement quand plus rien de neuf
    ne reste dans le filtre courant)."""
    with _LOCK:
        data = _read()
    ids = ordered_ids(platform)
    if not ids:
        return None
    start_after = after_id if after_id is not None else data.get("cursor")
    start_idx = 0
    if start_after in ids:
        start_idx = ids.index(start_after) + 1
    n = len(ids)
    for offset in range(n):
        candidate = ids[(start_idx + offset) % n]
        if candidate not in data["done"]:
            return candidate
    return ids[start_idx % n]  # tout est fait dans ce filtre : on repasse depuis le curseur
