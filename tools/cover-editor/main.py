import uvicorn
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from config import LUDODEX_SITE, PORT
from api.routes import router

app = FastAPI(title="Ludodex — Éditeur de jaquettes")
app.include_router(router)

# Sert les feuilles de style réelles du site Ludodex, en lecture seule, pour que l'aperçu
# de recadrage soit un rendu identique à la vraie carte (pas une approximation graphique).
app.mount("/ludodex-css", StaticFiles(directory=str(LUDODEX_SITE / "css")), name="ludodex-css")
app.mount("/static", StaticFiles(directory="static"), name="static")

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=PORT, reload=False)
