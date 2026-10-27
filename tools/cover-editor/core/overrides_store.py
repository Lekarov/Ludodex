"""Lecture/écriture atomique du VRAI fichier utilisé par le site (surcouche jaquettes).

Ne touche jamais aux catalogues sources Codex. Écriture atomique (tempfile + os.replace)
comme config.py/cleanup_store.py dans AutoDeleterr, pour éviter un fichier corrompu si
le process est coupé pendant l'écriture.
"""
import json
import os
import tempfile
from threading import Lock

from config import OVERRIDES_FILE

_LOCK = Lock()


def _read():
    if not OVERRIDES_FILE.exists():
        return {}
    with open(OVERRIDES_FILE, encoding="utf-8") as f:
        content = f.read().strip()
        return json.loads(content) if content else {}


def _write(data):
    OVERRIDES_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=OVERRIDES_FILE.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, OVERRIDES_FILE)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise


def get(game_id):
    with _LOCK:
        return _read().get(game_id)


def set_override(game_id, cover_url=None, object_position=None, zoom=None):
    """Enregistre/actualise la surcouche d'un jeu. Un champ omis (None) efface juste ce champ ;
    si les deux deviennent vides, l'entrée entière est retirée (pas d'objet {} qui traîne)."""
    with _LOCK:
        data = _read()
        entry = dict(data.get(game_id) or {})
        if cover_url:
            entry["coverUrl"] = cover_url
        else:
            entry.pop("coverUrl", None)
        if object_position:
            entry["objectPosition"] = object_position
        else:
            entry.pop("objectPosition", None)
        if zoom and abs(zoom - 1) > 0.001:
            entry["zoom"] = zoom
        else:
            entry.pop("zoom", None)
        if entry:
            from datetime import datetime, timezone
            entry["updatedAt"] = datetime.now(timezone.utc).isoformat()
            data[game_id] = entry
        else:
            data.pop(game_id, None)
        _write(data)
        return data.get(game_id)


def remove_override(game_id):
    with _LOCK:
        data = _read()
        if game_id in data:
            del data[game_id]
            _write(data)
