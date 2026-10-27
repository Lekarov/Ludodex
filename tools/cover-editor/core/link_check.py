"""Vérifie qu'un lien collé par l'utilisateur est effectivement une image utilisable,
avant qu'il finisse dans le fichier de surcouche réel du site.

Sécurité : ce serveur va faire une requête HTTP vers une URL fournie par l'utilisateur.
Sans garde-fou, c'est une SSRF classique (le serveur peut être détourné pour sonder le
réseau local ou des services internes). Garde-fous appliqués :
- schéma http/https uniquement (jamais file:, data:, javascript:, ftp:...) ;
- résolution DNS puis rejet si l'IP obtenue est privée/loopback/lien-local/multicast
  (bloque aussi l'IP de métadonnées cloud 169.254.169.254) ;
- une seule requête HEAD, redirections non suivies automatiquement (revérifiées à la main
  si présentes, une fois seulement) ;
- timeout court, taille de réponse non pertinente pour un HEAD.
"""
import ipaddress
import socket
from urllib.parse import urlparse

import requests

TIMEOUT = 5
ALLOWED_SCHEMES = {"http", "https"}
MAX_REDIRECTS = 1


def _is_private(ip_str):
    ip = ipaddress.ip_address(ip_str)
    return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved


def _resolve_is_safe(hostname):
    try:
        infos = socket.getaddrinfo(hostname, None)
    except socket.gaierror:
        return False, "nom de domaine introuvable"
    for info in infos:
        ip_str = info[4][0]
        if _is_private(ip_str):
            return False, "cible réseau interne refusée"
    return True, None


def check_image_url(url):
    """Retourne {ok, reason, content_type}."""
    for _ in range(MAX_REDIRECTS + 1):
        parsed = urlparse(url)
        if parsed.scheme not in ALLOWED_SCHEMES:
            return {"ok": False, "reason": "seuls les liens http/https sont acceptés"}
        if not parsed.hostname:
            return {"ok": False, "reason": "lien invalide"}
        safe, reason = _resolve_is_safe(parsed.hostname)
        if not safe:
            return {"ok": False, "reason": reason}
        try:
            res = requests.head(url, timeout=TIMEOUT, allow_redirects=False)
        except requests.RequestException as err:
            return {"ok": False, "reason": f"inaccessible ({err.__class__.__name__})"}
        if res.status_code in (301, 302, 303, 307, 308) and "location" in res.headers:
            url = res.headers["location"]
            continue
        if not (200 <= res.status_code < 300):
            return {"ok": False, "reason": f"le lien répond {res.status_code}"}
        content_type = res.headers.get("content-type", "")
        if not content_type.startswith("image/"):
            return {"ok": False, "reason": f"ce n'est pas une image (type reçu : {content_type or 'inconnu'})"}
        return {"ok": True, "reason": None, "content_type": content_type}
    return {"ok": False, "reason": "trop de redirections"}
