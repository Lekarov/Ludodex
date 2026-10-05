let myCollection = []; // [{card_id, shiny, count, card_catalogue: {...}}]

/* ===== Collection : filtres (recherche, plateforme, rareté — façon WikiMasters) ===== */
let fSearch = "";
let fPlat = "";
let fRarity = new Set(); // vide = toutes les raretés ; sinon multi-sélection (voir 28/09/2026)
let fRarityInited = false; // le défaut (raretés possédées) n'est posé qu'une fois, au 1er chargement

function syncRarityControls(){
  document.querySelectorAll("#rarTabs [data-rar]").forEach(b => b.setAttribute("aria-pressed", String(fRarity.has(+b.dataset.rar))));
}

let ddPlat;

function renderPlatDropdown(){
  const plats = [...new Set(myCollection.map(r => r.card_catalogue.platform_name))].sort((a, b) => a.localeCompare(b, "fr"));
  if (!plats.includes(fPlat)) fPlat = "";
  ddPlat.label.textContent = fPlat || "Toutes les plateformes";
  ddPlat.panel.innerHTML = '<button type="button" class="dd-opt' + (fPlat === "" ? " sel" : "") + '" data-value="">Toutes les plateformes</button>' +
    plats.map(p => '<button type="button" class="dd-opt' + (fPlat === p ? " sel" : "") + '" data-value="' + esc(p) + '">' + esc(p) + '</button>').join("");
}

function initCollFilters(){
  document.getElementById("rarTabs").innerHTML = RARITY_ORDER.map((_, i) => i).reverse().map(i => {
    const r = RARITY_ORDER[i];
    return '<button type="button" data-rar="' + i + '" style="--rc:' + r.color + '" aria-pressed="false" title="' + esc(r.name) + '">' + esc(r.abbr) + '</button>';
  }).join("") + '<button type="button" class="rarreset" id="rarReset">× Réinitialiser rareté</button>';
  document.getElementById("rarTabs").addEventListener("click", (e) => {
    const reset = e.target.closest("#rarReset");
    if (reset){ fRarity.clear(); syncRarityControls(); renderCollectionGrid(); return; }
    const b = e.target.closest("[data-rar]");
    if (!b) return;
    const i = +b.dataset.rar;
    if (fRarity.has(i)) fRarity.delete(i); else fRarity.add(i);
    syncRarityControls();
    renderCollectionGrid();
  });

  ddPlat = setupDropdown("ddPlat");
  ddPlat.panel.addEventListener("click", (e) => {
    const b = e.target.closest("[data-value]");
    if (!b) return;
    fPlat = b.dataset.value;
    renderPlatDropdown();
    closeAllDropdowns();
    renderCollectionGrid();
  });

  document.getElementById("fSearch").addEventListener("input", (e) => {
    fSearch = e.target.value.trim().toLowerCase();
    renderCollectionGrid();
  });
}

function renderCollectionGrid(){
  // Par défaut (une seule fois, au premier chargement des cartes possédées) : les chips de
  // rareté s'allument sur tout ce que le joueur possède déjà — pas de carte cachée par surprise,
  // juste un état de filtre qui reflète honnêtement la collection réelle.
  if (!fRarityInited && myCollection.length){
    fRarityInited = true;
    myCollection.forEach(row => fRarity.add(row.card_catalogue.rarity));
    syncRarityControls();
  }
  const q = fSearch;
  const list = myCollection.filter(row => {
    const g = row.card_catalogue;
    if (fRarity.size && !fRarity.has(g.rarity)) return false;
    if (fPlat && g.platform_name !== fPlat) return false;
    if (q && !(g.title.toLowerCase().includes(q) || g.platform_name.toLowerCase().includes(q))) return false;
    return true;
  });

  document.getElementById("collectionGrid").innerHTML = list.length ? list.map(row => {
    return '<div class="cw-click" data-open="' + esc(row.card_id) + '|' + (row.shiny ? 1 : 0) + '">' + cardBlockHTML(row.card_catalogue, row.shiny, { count: row.count }) + '</div>';
  }).join("") : '<p class="empty">Aucune carte ne correspond à ces filtres.</p>';
}

/* ===== Collection : mode grille ===== */
let collMode = "grid";
document.getElementById("collMode").addEventListener("click", (e) => {
  const b = e.target.closest("[data-cm]");
  if (!b) return;
  collMode = b.dataset.cm;
  document.querySelectorAll("#collMode [data-cm]").forEach(x => x.setAttribute("aria-pressed", x === b ? "true" : "false"));
  document.getElementById("collGrid").hidden = collMode !== "grid";
  document.getElementById("collAlbum").hidden = collMode !== "album";
  if (collMode === "album" && !albumLoaded) loadAlbumShelf();
});

async function loadCollection(){
  document.getElementById("collectionStatus").textContent = "Chargement…";
  const { data, error } = await supabaseClient
    .from("collection")
    .select("card_id, shiny, count, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id)
    .order("obtained_at", { ascending: false });
  if (error){ document.getElementById("collectionStatus").textContent = "Erreur : " + error.message; return; }

  myCollection = data;
  document.getElementById("collectionStatus").textContent = data.length
    ? (data.length + " carte" + (data.length > 1 ? "s" : "") + " différente" + (data.length > 1 ? "s" : "") + ".")
    : "Pas encore de carte — ouvre un booster !";

  renderPlatDropdown();
  renderCollectionGrid();
}

document.getElementById("collectionGrid").addEventListener("click", async (e) => {
  const openEl = e.target.closest("[data-open]");
  if (openEl){
    const [cardId, sh] = openEl.dataset.open.split("|");
    const row = myCollection.find(r => r.card_id === cardId && String(r.shiny ? 1 : 0) === sh);
    if (row) openDetail(row.card_id, row.shiny, row.card_catalogue, row.count);
  }
});

/* ===== Collection : mode album (étagère par plateforme) ===== */
let albumLoaded = false;
let albumPlat = null;

async function loadAlbumShelf(){
  document.getElementById("albumStatus").textContent = "Chargement…";
  // Vraie agrégation côté serveur (069_platform_card_totals.sql, vue GROUP BY) : ~40 lignes en
  // retour. Rapatrier card_catalogue en entier pour compter en JS (ancien code) se faisait
  // silencieusement tronquer à 1000 lignes par le plafond PostgREST — totaux par plateforme faux.
  const { data: totals, error: totalsErr } = await supabaseClient
    .from("platform_card_totals")
    .select("platform_name, family_color, total");
  if (totalsErr){ document.getElementById("albumStatus").textContent = "Erreur : " + totalsErr.message; return; }

  const byPlat = {};
  totals.forEach(row => {
    byPlat[row.platform_name] = { name: row.platform_name, color: row.family_color, total: row.total, owned: 0 };
  });

  if (!myCollection.length) await loadCollectionSilently();
  const { data: ownedRows } = await supabaseClient
    .from("collection")
    .select("card_id, card_catalogue(platform_name)")
    .eq("profile_id", session.user.id);
  // "Possédées" = cartes DISTINCTES par plateforme, pas nombre de lignes : la même carte possédée
  // à la fois en normale ET en brillante fait deux lignes dans `collection` (clé (profil, carte,
  // brillante)) mais ne doit compter qu'une fois ici — sinon le total dépasse le nombre réel de
  // cartes du catalogue pour cette plateforme (bug constaté : "38/32" alors que toutes ne sont pas
  // possédées).
  const ownedIdsByPlat = {};
  (ownedRows || []).forEach(r => {
    const p = r.card_catalogue && r.card_catalogue.platform_name;
    if (!p || !byPlat[p]) return;
    if (!ownedIdsByPlat[p]) ownedIdsByPlat[p] = new Set();
    ownedIdsByPlat[p].add(r.card_id);
  });
  Object.keys(ownedIdsByPlat).forEach(p => { byPlat[p].owned = ownedIdsByPlat[p].size; });

  albumLoaded = true;
  albumByPlat = byPlat; // réutilisé par openAlbumPlatform (total/possédées déjà connus, pas re-comptés par page)
  const list = Object.values(byPlat).sort((a, b) => a.name.localeCompare(b.name));
  document.getElementById("albumStatus").textContent = list.length + " plateformes.";
  document.getElementById("binders").innerHTML = list.map(x => {
    const done = x.owned >= x.total;
    return '<button class="binder' + (done ? " done" : "") + '" type="button" data-plat="' + esc(x.name) + '" style="--pc:' + x.color + '">' +
      (done ? '<span class="star" aria-label="Complet">★</span>' : "") +
      '<span class="bn">' + esc(x.name) + '</span>' +
      '<span><span class="bc">' + x.owned + ' / ' + x.total + (done ? ", complet" : (x.owned ? ", il en manque " + (x.total - x.owned) : "")) + '</span>' +
      '<span class="bb"><i style="width:' + (x.owned / x.total * 100) + '%"></i></span></span></button>';
  }).join("");
}

async function loadCollectionSilently(){
  const { data } = await supabaseClient
    .from("collection")
    .select("card_id, shiny, count, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id);
  myCollection = data || [];
}

document.getElementById("binders").addEventListener("click", (e) => {
  const b = e.target.closest("[data-plat]");
  if (!b) return;
  albumRarity = null;
  openAlbumPlatform(b.dataset.plat, 0);
});

// Pagination de la page d'album : une plateforme comme Arcade dépasse le millier de cartes,
// tout charger/afficher d'un coup rendait la page interminable à faire défiler. Chaque page ne
// récupère que sa tranche (range()), le total/possédées viennent du décompte déjà fait par
// loadAlbumShelf (albumByPlat) — pas besoin de recompter à chaque changement de page.
const ALBUM_PAGE_SIZE = 100;
let albumByPlat = {};
let albumPage = 0;

function pagerHTML(current, totalPages){
  if (totalPages <= 1) return "";
  const nums = new Set([0, totalPages - 1, current, current - 1, current + 1]);
  const pages = [...nums].filter(p => p >= 0 && p < totalPages).sort((a, b) => a - b);
  let html = '<nav class="pager" aria-label="Pages de l\'album">' +
    '<button type="button" class="pgbtn" data-pg="' + (current - 1) + '"' + (current === 0 ? " disabled" : "") + ' aria-label="Page précédente">‹</button>';
  let prev = null;
  for (const p of pages){
    if (prev !== null && p - prev > 1) html += '<span class="pgdots">…</span>';
    html += '<button type="button" class="pgbtn' + (p === current ? " cur" : "") + '" data-pg="' + p + '" aria-current="' + (p === current ? "true" : "false") + '">' + (p + 1) + '</button>';
    prev = p;
  }
  html += '<button type="button" class="pgbtn" data-pg="' + (current + 1) + '"' + (current === totalPages - 1 ? " disabled" : "") + ' aria-label="Page suivante">›</button>' +
    '</nav>';
  return html;
}

// Filtre de rareté de l'album (par plateforme) — un seul choix à la fois, réinitialisé en
// changeant de plateforme. Rendu très discret : mêmes lettres colorées que .rartabs (card.css),
// juste un anneau de couleur quand actif, pas de fond plein — cohérent avec le reste du site.
let albumRarity = null;

function albumRarTabsHTML(){
  return '<div class="rartabs album-rartabs">' +
    RARITY_ORDER.map((_, i) => i).reverse().map(i => {
      const r = RARITY_ORDER[i];
      return '<button type="button" data-arar="' + i + '" style="--rc:' + r.color + '" aria-pressed="' + (albumRarity === i) + '" title="' + esc(r.name) + '">' + esc(r.abbr) + '</button>';
    }).join("") +
    (albumRarity !== null ? '<button type="button" class="rarreset" id="albumRarReset">× Réinitialiser rareté</button>' : "") +
    '</div>';
}

async function openAlbumPlatform(name, pageIndex){
  albumPlat = name;
  document.getElementById("shelf").hidden = true;
  document.getElementById("apage").hidden = false;
  document.getElementById("apage").innerHTML = '<p class="sub">Chargement…</p>';

  const meta = albumByPlat[name] || { total: 0, owned: 0, color: "#8a6d3b" };

  // Tri "possédées d'abord, par rareté" fait côté serveur (070_browse_platform_cards.sql) : une
  // plateforme peut avoir des dizaines de milliers de cartes, impossible de trier ça correctement
  // en ne rapatriant qu'une page à la fois sans agrégation serveur (même piège que 069).
  const from = albumPage * ALBUM_PAGE_SIZE;
  const { data: page, error } = await supabaseClient.rpc("browse_platform_cards", {
    p_platform: name, p_rarity: albumRarity, p_limit: ALBUM_PAGE_SIZE, p_offset: from,
  });
  if (error){ document.getElementById("apage").innerHTML = '<p class="sub">Erreur : ' + esc(error.message) + '</p>'; return; }

  const cards = page.items || [];
  const filteredTotal = page.total || 0;
  const totalPages = Math.max(1, Math.ceil(filteredTotal / ALBUM_PAGE_SIZE));
  albumPage = Math.min(Math.max(0, pageIndex || 0), totalPages - 1);

  const done = meta.owned >= meta.total && meta.total > 0;
  const pc = meta.color || (cards[0] ? cards[0].family_color : "#8a6d3b");
  const pager = pagerHTML(albumPage, totalPages);

  document.getElementById("apage").innerHTML = '<button class="aback" type="button" id="albumBackBtn">‹ Retour à l’étagère</button>' +
    '<div class="apage' + (done ? " complete" : "") + '" style="--pc:' + pc + '">' +
    (done ? '<span class="stamp">COMPLET</span>' : "") +
    '<div class="ahead"><h2>' + esc(name) + '<small>' + meta.owned + ' / ' + meta.total + ' cartes</small></h2></div>' +
    '<div class="abar"><i style="width:' + (meta.total ? meta.owned / meta.total * 100 : 0) + '%"></i></div>' +
    albumRarTabsHTML() +
    pager +
    '<div class="aslots">' + cards.map((g, i) => {
      const inner = g.owned
        ? '<div class="cw slot">' + cardHTML(g, { count: g.owned_count, shiny: g.owned_shiny }) + '</div>'
        : '<div class="cw slot">' + ghostHTML(g) + '</div>';
      return '<div class="aslot"><span class="anum">n°' + (from + i + 1) + '</span>' + inner + '</div>';
    }).join("") + '</div>' +
    pager +
    '</div>';

  document.getElementById("albumBackBtn").addEventListener("click", () => {
    albumPlat = null;
    document.getElementById("apage").hidden = true;
    document.getElementById("shelf").hidden = false;
  });
  document.getElementById("apage").querySelectorAll(".pager").forEach(nav => {
    nav.addEventListener("click", (e) => {
      const b = e.target.closest("[data-pg]");
      if (!b || b.disabled) return;
      openAlbumPlatform(name, +b.dataset.pg);
      document.getElementById("apage").scrollIntoView({ behavior: "smooth", block: "start" });
    });
  });
  document.querySelector(".album-rartabs").addEventListener("click", (e) => {
    const reset = e.target.closest("#albumRarReset");
    if (reset){ albumRarity = null; openAlbumPlatform(name, 0); return; }
    const b = e.target.closest("[data-arar]");
    if (!b) return;
    const i = +b.dataset.arar;
    albumRarity = albumRarity === i ? null : i;
    openAlbumPlatform(name, 0);
  });
}


(async function(){ if (!(await initPage())) return; initCollFilters(); await loadCollection(); })();
