from fastapi import APIRouter, Form
from fastapi.responses import RedirectResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

from core import catalogue, overrides_store, progress_store, link_check

router = APIRouter()
templates = Jinja2Templates(directory="templates")


def _game_view(game_id):
    g = catalogue.get_game(game_id)
    if not g:
        return None
    override = overrides_store.get(game_id) or {}
    return {
        **g,
        "override_cover_url": override.get("coverUrl"),
        "object_position": override.get("objectPosition") or "50% 20%",
        "zoom": override.get("zoom") or 1,
        "has_override": bool(override),
    }


@router.get("/")
def home(request: Request, id: str | None = None, platform: str | None = None):
    if platform is not None:
        progress_store.set_filter(platform)
    current_filter = platform if platform is not None else progress_store.get_filter()
    game_id = id or progress_store.next_id(platform=current_filter)
    game = _game_view(game_id) if game_id else None
    return templates.TemplateResponse(request, "editor.html", {
        "game": game,
        "stats": progress_store.stats(current_filter),
        "platforms": catalogue.platforms_list(),
        "current_filter": current_filter or "",
    })


@router.get("/api/search")
def api_search(q: str = "", platform: str = ""):
    return JSONResponse(catalogue.search(q, platform=platform or None))


@router.get("/api/check-image")
def api_check_image(url: str = ""):
    if not url.strip():
        return JSONResponse({"ok": False, "reason": "lien vide"})
    return JSONResponse(link_check.check_image_url(url.strip()))


@router.post("/save")
def save(
    game_id: str = Form(...),
    cover_url: str = Form(""),
    object_position: str = Form(""),
    zoom: str = Form("1"),
    advance: str = Form("1"),
    platform: str = Form(""),
):
    try:
        zoom_value = float(zoom)
    except ValueError:
        zoom_value = 1.0
    zoom_value = max(1.0, min(3.0, zoom_value))
    overrides_store.set_override(
        game_id,
        cover_url=cover_url.strip() or None,
        object_position=object_position.strip() or None,
        zoom=zoom_value,
    )
    progress_store.mark_done(game_id)
    next_game = progress_store.next_id(game_id, platform=platform or None) if advance == "1" else game_id
    suffix = f"&platform={platform}" if platform else ""
    return RedirectResponse(url=f"/?id={next_game}{suffix}", status_code=303)


@router.post("/skip")
def skip(game_id: str = Form(...), platform: str = Form("")):
    progress_store.mark_done(game_id)
    next_game = progress_store.next_id(game_id, platform=platform or None)
    suffix = f"&platform={platform}" if platform else ""
    return RedirectResponse(url=f"/?id={next_game}{suffix}", status_code=303)


@router.post("/clear")
def clear(game_id: str = Form(...), platform: str = Form("")):
    """Retire la surcouche existante (retour à la jaquette IGDB d'origine) sans avancer."""
    overrides_store.remove_override(game_id)
    suffix = f"&platform={platform}" if platform else ""
    return RedirectResponse(url=f"/?id={game_id}{suffix}", status_code=303)
