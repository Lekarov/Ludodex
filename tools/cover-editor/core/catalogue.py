"""Lecture seule des catalogues réels Ludodex (jamais de modification, jamais de copie sur disque).

Reproduit uniquement la fusion par clé (priorité au dernier fichier chargé qui gagne,
comme catalogue-loader.js) pour les champs utiles à cet outil : id, titre, plateformes,
année, jaquette. Pas de calcul de rareté/ATK/DEF, inutile ici.
"""
import json
from functools import lru_cache

from config import CATALOGUE_FILES


def _load_one(path):
    if not path.exists():
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=1)
def load_merged_catalogue():
    """Retourne {id: {id,title,platforms,year,cover_url,thumb_url}}, trié une seule fois
    et gardé en mémoire pour la durée du process (redémarrer l'outil si Codex ajoute un volume)."""
    merged = {}
    for path, label in CATALOGUE_FILES:
        data = _load_one(path)
        for key, e in data.items():
            cover = e.get("cover") or {}
            merged[key] = {
                "id": key,
                "title": e.get("title") or "(titre inconnu)",
                "platforms": e.get("platforms") or [],
                "year": e.get("year"),
                "cover_url": cover.get("url"),
                "thumb_url": cover.get("square_url") or cover.get("url"),
            }
    return merged


@lru_cache(maxsize=1)
def platforms_list():
    """Plateformes distinctes triées, pour peupler le filtre. Calculé une seule fois."""
    plats = set()
    for g in load_merged_catalogue().values():
        plats.update(g["platforms"])
    return sorted(plats)


def ordered_ids(platform=None):
    """Ordre stable (tri par id) : garantit que 'suivante' avance toujours dans le même sens
    d'une session à l'autre, même si l'ordre des fichiers change côté Codex.
    Si platform est fourni, ne garde que les jeux qui listent cette plateforme."""
    catalogue = load_merged_catalogue()
    ids = sorted(catalogue.keys())
    if platform:
        ids = [k for k in ids if platform in catalogue[k]["platforms"]]
    return ids


def get_game(game_id):
    return load_merged_catalogue().get(game_id)


def search(query, platform=None, limit=20):
    q = (query or "").strip().lower()
    if not q:
        return []
    out = []
    for g in load_merged_catalogue().values():
        if platform and platform not in g["platforms"]:
            continue
        if q in g["title"].lower():
            out.append(g)
            if len(out) >= limit:
                break
    return out
