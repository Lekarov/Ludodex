"""Serveur HTTP local pour Ludodex Online, avec en-tetes anti-cache.

Un simple `python -m http.server` sert de vieilles versions de CSS/JS apres une
modification (le navigateur les met en cache) - piege deja rencontre sur ce projet.
Usage : python serve_nocache.py [port]  (depuis le dossier "Ludodex Online")
"""
import http.server
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
DIRECTORY = "web"

# Meme politique que la balise <meta http-equiv="Content-Security-Policy"> posee sur chaque page
# HTML (portable vers n'importe quel hebergeur statique), mais en vrai en-tete HTTP ici : ca
# couvre en plus frame-ancestors, ignore par la balise meta selon la spec CSP.
CSP = (
    "default-src 'self'; "
    "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
    "font-src 'self' https://fonts.gstatic.com; "
    "img-src 'self' data: https:; "
    "connect-src 'self' https://*.supabase.co wss://*.supabase.co https://api.ipify.org; "
    "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
)

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.send_header("Content-Security-Policy", CSP)
        super().end_headers()

class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

with ThreadingTCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"Ludodex Online servi sur http://127.0.0.1:{PORT}")
    httpd.serve_forever()
