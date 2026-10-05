/* "Toutes les cartes" — parcourir le catalogue complet : jeux (card_catalogue) ET personnages
   (character_catalogue), unifiés par la vue all_cards_catalogue (voir 048_all_cards_view.sql).
   Avec ou sans les posséder (la possession/liste de souhaits/marché n'existent que pour les jeux
   — voir detail.js). Pagination par page ("Charger plus"), jamais tout chargé d'un coup. */

const PAGE_SIZE = 60;
const FRANCHISES = [
  "Animal Crossing", "Pokémon", "League of Legends", "Magic: The Gathering", "Yu-Gi-Oh!",
  "Hearthstone", "Genshin Impact", "Honkai: Star Rail", "Dota 2", "Valorant", "Fortnite",
  "Digimon", "Fate/Grand Order", "Nintendo (Amiibo)",
];
// Mêmes libellés que pickPlatform() dans generate_card_catalogue.js — pas de requête "distinct"
// séparée (coûteuse sur 195 000+ lignes), cette liste est stable tant que le générateur ne change pas.
const PLATFORMS = [
  "PC", "PlayStation 5", "Xbox Series X/S", "PlayStation 4", "Xbox One", "Switch 2", "Switch",
  "PlayStation 3", "Xbox 360", "Wii U", "Wii", "PlayStation 2", "PlayStation", "GameCube",
  "Nintendo 64", "Nintendo 3DS", "Nintendo DS", "Game Boy Advance", "Game Boy Color", "Game Boy",
  "Super Nintendo", "NES", "PS Vita", "PSP", "PS VR2", "PS VR", "Réalité virtuelle", "Dreamcast",
  "Saturn", "Mega Drive", "Game Gear", "Master System", "Sega CD / 32X", "Neo Geo", "Arcade",
  "Atari 2600", "Atari (autre)", "3DO", "Xbox", "Mobile", "Navigateur", "Cloud",
];
let cardsSearch = "";
let cardsRarity = new Set([5]); // défaut = Mythique seule (la plus rare), pour économiser le
                                 // chargement sur ~239 000 lignes ; multi-sélection sinon (28/09)
let cardsKind = "";       // "" = tout, "game", "character"
let cardsFranchise = "";  // filtre actif seulement quand cardsKind === "character"
let cardsPlatform = "";   // filtre actif seulement quand cardsKind !== "character"
let wishlistOnly = false;
let wishlistIds = null; // Set, chargé seulement si le filtre est activé
let page = 0;
let loading = false;
let exhausted = false;

function cardsQuery(){
  let q = supabaseClient.from("all_cards_catalogue").select("card_id, kind, " + CARD_FIELDS).order("title", { ascending: true });
  if (cardsRarity.size) q = q.in("rarity", [...cardsRarity]);
  if (cardsKind) q = q.eq("kind", cardsKind);
  if (cardsKind === "character" && cardsFranchise) q = q.eq("platform_name", cardsFranchise);
  if (cardsKind !== "character" && cardsPlatform) q = q.eq("platform_name", cardsPlatform);
  if (cardsSearch) q = q.or("title.ilike.%" + cardsSearch + "%,platform_name.ilike.%" + cardsSearch + "%");
  if (wishlistOnly && wishlistIds) q = q.in("card_id", [...wishlistIds]);
  return q;
}

async function loadWishlistIds(){
  if (wishlistIds) return wishlistIds;
  const { data } = await supabaseClient.from("wishlist").select("card_id").eq("profile_id", session.user.id);
  wishlistIds = new Set((data || []).map(r => r.card_id));
  return wishlistIds;
}

async function loadPage(reset){
  if (loading) return;
  if (reset){ page = 0; exhausted = false; document.getElementById("cardsGrid").innerHTML = ""; }
  if (exhausted) return;
  loading = true;
  document.getElementById("cardsStatus").textContent = "Chargement…";
  document.getElementById("loadMoreBtn").hidden = true;

  if (wishlistOnly) await loadWishlistIds();
  if (wishlistOnly && wishlistIds.size === 0){
    exhausted = true;
    loading = false;
    document.getElementById("cardsStatus").textContent = "Ta liste de souhaits est vide pour l'instant.";
    return;
  }

  const from = page * PAGE_SIZE, to = from + PAGE_SIZE - 1;
  const { data, error } = await cardsQuery().range(from, to);
  loading = false;
  if (error){ document.getElementById("cardsStatus").textContent = "Erreur : " + error.message; return; }

  (data || []).forEach(card => { lastBatch[card.card_id] = card; });

  const grid = document.getElementById("cardsGrid");
  grid.insertAdjacentHTML("beforeend", (data || []).map(card =>
    '<div class="cw-click" data-open="' + esc(card.card_id) + '">' + cardBlockHTML(card, false, {}) + '</div>'
  ).join(""));

  page++;
  if (!data || data.length < PAGE_SIZE) exhausted = true;
  document.getElementById("cardsStatus").textContent = grid.children.length
    ? grid.children.length + " carte" + (grid.children.length > 1 ? "s" : "") + " affichée" + (grid.children.length > 1 ? "s" : "") + (exhausted ? "." : ", plus à charger.")
    : "Aucune carte ne correspond à ces filtres.";
  document.getElementById("loadMoreBtn").hidden = exhausted;
}

// Carte déjà en mémoire depuis le dernier lot chargé : pas besoin d'une requête réseau
// supplémentaire pour ouvrir le détail au clic.
let lastBatch = {};

document.getElementById("cardsGrid").addEventListener("click", (e) => {
  const el = e.target.closest("[data-open]");
  if (!el) return;
  openDetail(el.dataset.open, false, lastBatch[el.dataset.open], 0);
});

document.getElementById("loadMoreBtn").addEventListener("click", () => loadPage(false));

document.getElementById("cardsSearch").addEventListener("input", (e) => {
  // ,()* ont un sens spécial dans la syntaxe de filtre PostgREST utilisée par .or() ci-dessus —
  // retirés pour qu'une recherche ne puisse jamais casser ou détourner la requête.
  cardsSearch = e.target.value.trim().replace(/[,()*]/g, "");
  clearTimeout(window.__cardsSearchTimer);
  window.__cardsSearchTimer = setTimeout(() => loadPage(true), 300);
});

document.getElementById("wishToggle").addEventListener("click", async (e) => {
  wishlistOnly = !wishlistOnly;
  e.currentTarget.setAttribute("aria-pressed", String(wishlistOnly));
  e.currentTarget.textContent = wishlistOnly ? "★" : "☆";
  if (wishlistOnly) wishlistIds = null; // force un rechargement à jour
  await loadPage(true);
});

function syncCardsRarityControls(){
  document.querySelectorAll("#cardsRarTabs [data-rar]").forEach(x => x.setAttribute("aria-pressed", String(cardsRarity.has(+x.dataset.rar))));
}
document.getElementById("cardsRarTabs").innerHTML = RARITY_ORDER.map((_, i) => i).reverse().map(i => {
  const r = RARITY_ORDER[i];
  return '<button type="button" data-rar="' + i + '" style="--rc:' + r.color + '" aria-pressed="false" title="' + esc(r.name) + '">' + esc(r.abbr) + '</button>';
}).join("") + '<button type="button" class="rarreset" id="cardsRarReset">× Réinitialiser rareté</button>';
syncCardsRarityControls();
document.getElementById("cardsRarTabs").addEventListener("click", (e) => {
  const reset = e.target.closest("#cardsRarReset");
  if (reset){ cardsRarity.clear(); syncCardsRarityControls(); loadPage(true); return; }
  const b = e.target.closest("[data-rar]");
  if (!b) return;
  const i = +b.dataset.rar;
  if (cardsRarity.has(i)) cardsRarity.delete(i); else cardsRarity.add(i);
  syncCardsRarityControls();
  loadPage(true);
});

async function loadRaritySummary(){
  const counts = await Promise.all(RARITY_ORDER.map((_, i) => {
    let q = supabaseClient.from("all_cards_catalogue").select("card_id", { count: "exact", head: true }).eq("rarity", i);
    if (cardsKind) q = q.eq("kind", cardsKind);
    return q;
  }));
  document.getElementById("raritySum").innerHTML = RARITY_ORDER.map((r, i) =>
    '<span><span class="dot" style="background:' + r.color + '"></span>' + esc(r.name) + ' : <b>' + fmt(counts[i].count || 0) + '</b></span>'
  ).join("");
}

let ddFranchise, ddCardsPlat;
function renderFranchiseDropdown(){
  ddFranchise.label.textContent = cardsFranchise || "Toutes les franchises";
  ddFranchise.panel.innerHTML = '<button type="button" class="dd-opt' + (cardsFranchise === "" ? " sel" : "") + '" data-value="">Toutes les franchises</button>' +
    FRANCHISES.map(f => '<button type="button" class="dd-opt' + (cardsFranchise === f ? " sel" : "") + '" data-value="' + esc(f) + '">' + esc(f) + '</button>').join("");
}
function renderCardsPlatDropdown(){
  ddCardsPlat.label.textContent = cardsPlatform || "Toutes les plateformes";
  ddCardsPlat.panel.innerHTML = '<button type="button" class="dd-opt' + (cardsPlatform === "" ? " sel" : "") + '" data-value="">Toutes les plateformes</button>' +
    PLATFORMS.map(p => '<button type="button" class="dd-opt' + (cardsPlatform === p ? " sel" : "") + '" data-value="' + esc(p) + '">' + esc(p) + '</button>').join("");
}

document.getElementById("kindTabs").addEventListener("click", (e) => {
  const b = e.target.closest("[data-kind]");
  if (!b) return;
  cardsKind = b.dataset.kind;
  document.querySelectorAll("#kindTabs button").forEach(x => x.setAttribute("aria-pressed", String(x === b)));
  document.getElementById("ddFranchise").hidden = cardsKind !== "character";
  document.getElementById("ddCardsPlat").hidden = cardsKind === "character";
  if (cardsKind !== "character"){ cardsFranchise = ""; renderFranchiseDropdown(); }
  else { cardsPlatform = ""; renderCardsPlatDropdown(); }
  loadRaritySummary();
  loadPage(true);
});

(async function(){
  if (!(await initPage())) return;
  ddFranchise = setupDropdown("ddFranchise");
  renderFranchiseDropdown();
  ddFranchise.panel.addEventListener("click", (e) => {
    const b = e.target.closest("[data-value]");
    if (!b) return;
    cardsFranchise = b.dataset.value;
    renderFranchiseDropdown();
    closeAllDropdowns();
    loadPage(true);
  });
  ddCardsPlat = setupDropdown("ddCardsPlat");
  renderCardsPlatDropdown();
  ddCardsPlat.panel.addEventListener("click", (e) => {
    const b = e.target.closest("[data-value]");
    if (!b) return;
    cardsPlatform = b.dataset.value;
    renderCardsPlatDropdown();
    closeAllDropdowns();
    loadPage(true);
  });
  loadRaritySummary();
  await loadPage(true);
})();
