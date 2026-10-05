// Partagé par toutes les pages connectées (Boosters/Collection/Marché/Succès/Social/Profil) :
// vérifie la session, alimente le statut de compte (pièces/boosters) affiché en haut de chaque
// page. Chaque page reste un vrai fichier séparé (pas d'onglets cachés en JS) ; ce script est ce
// qu'elles ont en commun.
let session = null;
let hud = { coins: 0, boosters_available: 0, last_regen_at: null };
const REGEN_MS = 10 * 60 * 1000; // doit rester identique à celui utilisé par open_booster() côté serveur
const MAX_PACKS_DISPLAY = 10;

// Icônes de navigation : tracés SVG légers, monochromes et indépendants des emojis système.
const MENU_ICONS = {
  "boosters.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 7h8M9 17h6M8 11h8"/></svg>',
  "collection.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4h11a2 2 0 0 1 2 2v14H7a2 2 0 0 1-2-2z"/><path d="M7 4v14M9 8h6M9 12h6"/></svg>',
  "market.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 8h16l-1 11H5L4 8Z"/><path d="M7 8a5 5 0 0 1 10 0M8 12h8"/></svg>',
  "trades.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 8h13M14 4l4 4-4 4M19 16H6M10 12l-4 4 4 4"/></svg>',
  "duels.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m7 4 5 5-3 3-5-5zM17 4l-5 5 3 3 5-5zM9 12l-3 8M15 12l3 8M8 20h8"/></svg>',
  "achievements.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 4h8v5a4 4 0 0 1-8 0zM8 6H5v2a3 3 0 0 0 3 3M16 6h3v2a3 3 0 0 1-3 3M12 13v5M8 21h8"/></svg>',
  "messages.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h16v12H8l-4 3z"/><path d="M7 9h10M7 13h7"/></svg>',
  "social.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 19a6 6 0 0 1 12 0M15 15a5 5 0 0 1 6 4"/></svg>',
  "account.html": '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="3"/><path d="M5 20a7 7 0 0 1 14 0"/></svg>'
};
function initMenuIcons(){
  document.querySelectorAll(".snavitem").forEach(item=>{
    const icon=item.querySelector(".sicon"), key=(item.getAttribute("href")||"").split("?")[0].split("/").pop();
    if(icon&&MENU_ICONS[key]) icon.innerHTML=MENU_ICONS[key];
  });
  const bell=document.getElementById("notifBell");
  if(bell){
    [...bell.childNodes].filter(n=>n.nodeType===3).forEach(n=>n.remove());
    const svg=document.createElement("span"); svg.className="bell-icon"; svg.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 17h12l-1.5-2v-5a4.5 4.5 0 0 0-9 0v5zM10 20h4"/></svg>'; bell.prepend(svg);
  }
}
initMenuIcons();

function showMsg(id, text, kind){
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.className = "msg show " + kind;
}

async function requireSession(){
  const { data: { session: s } } = await supabaseClient.auth.getSession();
  if (!s){ window.location.href = "login.html"; return null; }
  session = s;
  return s;
}

async function refreshHud(){
  const { data, error } = await supabaseClient
    .from("player_state")
    .select("coins, boosters_available, last_regen_at")
    .eq("profile_id", session.user.id)
    .single();
  if (error){ console.error(error); return; }
  hud = data;
  renderHud();
}

function renderHud(){
  const coinsEl = document.getElementById("coins");
  if (coinsEl) coinsEl.textContent = hud.coins;

  // Estime le stock affiché comme le ferait le client d'origine (regen() dans packs.js) : purement
  // informatif, la vraie régénération est recalculée et fait foi côté serveur à l'ouverture.
  const elapsed = Date.now() - new Date(hud.last_regen_at).getTime();
  const gained = Math.floor(elapsed / REGEN_MS);
  const displayed = Math.min(MAX_PACKS_DISPLAY, hud.boosters_available + Math.max(0, gained));

  const packCountEl = document.getElementById("packCount");
  if (packCountEl) packCountEl.textContent = displayed;

  const timer = document.getElementById("timer");
  if (timer){
    if (displayed >= MAX_PACKS_DISPLAY){
      timer.textContent = "stock plein";
    } else {
      const left = Math.max(0, REGEN_MS - (elapsed % REGEN_MS));
      const s = Math.ceil(left / 1000);
      timer.textContent = "prochain dans " + Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }
  }

  const openBtn = document.getElementById("openBtn");
  const openLbl = document.getElementById("openLbl");
  if (openBtn) openBtn.disabled = displayed < 1;
  if (openLbl){
    openLbl.disabled = displayed < 1;
    openLbl.textContent = displayed < 1 ? "Plus de booster" : "Ouvrir";
  }
  const stockN = document.getElementById("stockN");
  if (stockN) stockN.textContent = displayed + " / " + MAX_PACKS_DISPLAY;
}
setInterval(renderHud, 1000);

async function initPage(){
  const s = await requireSession();
  if (!s) return false;
  await refreshHud();
  return true;
}

const CARD_FIELDS = "title, platform_name, year, developer, image_url, rarity, rarity_name, rarity_color, family_color, atk, def, description_en, description_fr, genres";

// Compte à rebours "Se termine dans …" d'une enchère — utilisé par market.js (grille) et
// listing.js (fiche détail, mise à jour à la seconde comme le fait WikiMasters).
function formatTimeLeft(endsAt){
  if (!endsAt) return "";
  const left = new Date(endsAt).getTime() - Date.now();
  if (left <= 0) return "Terminée";
  const totalSec = Math.floor(left / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (h > 0) return h + "h " + String(m).padStart(2, "0") + "m";
  return m + "m " + String(s).padStart(2, "0") + "s";
}

// Pseudo d'un profil (vendeur/acheteur/enchérisseur...) résolu en lot pour éviter une requête par
// ligne ; utilisé par market.js et listing.js.
const profileNameCache = {};
async function resolveProfileNames(ids){
  const missing = [...new Set(ids)].filter(id => id && !(id in profileNameCache));
  if (!missing.length) return;
  const { data } = await supabaseClient.from("profiles").select("id, username").in("id", missing);
  (data || []).forEach(p => { profileNameCache[p.id] = p.username; });
  missing.forEach(id => { if (!(id in profileNameCache)) profileNameCache[id] = "un joueur"; });
}

// Même 6 raretés/couleurs que card_catalogue.rarity côté serveur (0=Commune..5=Mythique,
// voir schema/catalogue_import/generate_card_catalogue.js). abbr : lettres affichées sur les
// onglets de rareté, façon WikiMasters (L/UR/SR/R/PC/C). Utilisé par collection.js et market.js.
const RARITY_ORDER = [
  { name: "Commune",     abbr: "C",  color: "#7d879c" },
  { name: "Peu commune", abbr: "PC", color: "#2f9e68" },
  { name: "Rare",        abbr: "R",  color: "#2f74d0" },
  { name: "Épique",      abbr: "É",  color: "#8a45d6" },
  { name: "Légendaire",  abbr: "L",  color: "#d99a14" },
  { name: "Mythique",    abbr: "M",  color: "#e0457b" },
];

// Menu déroulant maison (bouton + panneau custom), utilisé par toute page avec un .dd dans son
// HTML (voir css/theme.css) : remplace les <select> natifs pour matcher le style WikiMasters.
function setupDropdown(rootId){
  const root = document.getElementById(rootId);
  const btn = root.querySelector(".dd-btn");
  const label = root.querySelector(".dd-label");
  const panel = root.querySelector(".dd-panel");
  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    const willOpen = !root.classList.contains("open");
    closeAllDropdowns();
    if (willOpen){
      root.classList.add("open");
      panel.hidden = false;
      btn.setAttribute("aria-expanded", "true");
    }
  });
  return { root, btn, label, panel };
}
function closeAllDropdowns(){
  document.querySelectorAll(".dd.open").forEach(d => {
    d.classList.remove("open");
    d.querySelector(".dd-panel").hidden = true;
    d.querySelector(".dd-btn").setAttribute("aria-expanded", "false");
  });
}
document.addEventListener("click", closeAllDropdowns);

function cardBlockHTML(game, shiny, opts){
  opts = opts || {};
  if (!game) return '<div class="cw"><div class="card"><div class="cc-body"><h4 class="cc-title">Carte inconnue</h4></div></div></div>';
  const merged = Object.assign({ shiny: shiny }, opts);
  return '<div class="cw">' + cardHTML(game, merged) + '</div>';
}
