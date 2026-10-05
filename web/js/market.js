/* ===== Marché : onglets (Parcourir / Mes ventes / Mes enchères / Gagnées / Historique) ===== */
/* formatTimeLeft() est dans shared.js (utilisée aussi par listing.js, qui ne charge pas market.js). */

// Résout toute enchère active dont la date de fin est dépassée (voir 023_rpc_auctions.sql :
// n'importe quel joueur authentifié peut déclencher cette résolution, rien d'arbitraire ne peut
// en sortir puisqu'elle ne fait que constater les mises déjà posées).
async function resolveExpiredAuctions(){
  const { data: expired } = await supabaseClient
    .from("market_listings")
    .select("id")
    .eq("status", "active")
    .eq("listing_type", "auction")
    .lte("ends_at", new Date().toISOString());
  if (expired && expired.length){
    await Promise.all(expired.map(l => supabaseClient.rpc("resolve_auction", { p_listing_id: l.id })));
  }
}

// Pseudo du vendeur/acheteur d'une annonce : bot_name direct, ou pseudo du joueur (profiles,
// lecture publique) — resolveProfileNames/profileNameCache partagés via shared.js.
function sellerLabel(row){
  return row.seller_type === "bot" ? row.bot_name : (profileNameCache[row.seller_profile_id] || "…");
}

let myUsername = null;
async function getMyUsername(){
  if (myUsername) return myUsername;
  const { data } = await supabaseClient.from("profiles").select("username").eq("id", session.user.id).single();
  myUsername = (data && data.username) || "toi";
  return myUsername;
}

// Mise la plus haute par annonce (enchères), pour afficher "mise actuelle" et calculer le prix
// payé par le gagnant une fois l'enchère résolue.
async function topBidsFor(listingIds){
  const top = {};
  if (!listingIds.length) return top;
  const { data: bids } = await supabaseClient
    .from("market_bids")
    .select("listing_id, amount")
    .in("listing_id", listingIds)
    .order("amount", { ascending: false });
  (bids || []).forEach(b => { if (!(b.listing_id in top)) top[b.listing_id] = b.amount; });
  return top;
}

// Vignette de carte du marché, façon WikiMasters : toute la vignette est cliquable et mène à la
// fiche détail (listing.html) — aucune action (miser/acheter/annuler) ne se fait depuis la grille
// elle-même, seulement sur la fiche (voir listing.js). Deux colonnes prix/durée sur une seule
// ligne (label au-dessus de la valeur), puis "Vendu par X" en dessous.
function coinsInline(n){ return fmt(n) + '<span class="coin" aria-hidden="true"></span>'; }
function marketTileHTML(g, shiny, listingId, o){
  o = o || {};
  const badge = o.owned ? '<span class="badge owned">Possédée</span>' : (o.statusBadge || "");
  const right = o.rightLabel
    ? '<div class="mtcol end"><span class="mtlabel">' + esc(o.rightLabel) + '</span><span class="mtval' + (o.rightUrgent ? " urgent" : "") + '">' + o.rightValueHTML + '</span></div>'
    : "";
  const row = '<div class="mtrow"><div class="mtcol"><span class="mtlabel">' + esc(o.leftLabel) + '</span><span class="mtval' + (o.leftAccent ? " accent" : "") + '">' + o.leftValueHTML + '</span></div>' + right + '</div>';
  const seller = o.seller ? '<p class="mtseller">Vendu par ' + esc(o.seller) + '</p>' : "";
  const inner = cardBlockHTML(g, shiny, {}) + '<div class="mcardinfo">' + badge + row + seller + '</div>';
  return listingId
    ? '<a class="mcard" href="listing.html?id=' + esc(listingId) + '">' + inner + '</a>'
    : '<div class="mcard">' + inner + '</div>';
}

/* ===== Onglets ===== */
let currentTab = "browse";
let ownedSet = {}; // "cardId|shiny" -> true, pour le badge "Possédée"

async function loadOwnedSet(){
  const { data } = await supabaseClient.from("collection").select("card_id, shiny").eq("profile_id", session.user.id);
  ownedSet = {};
  (data || []).forEach(r => { ownedSet[r.card_id + "|" + (r.shiny ? 1 : 0)] = true; });
}

document.getElementById("mTabs").addEventListener("click", (e) => {
  const b = e.target.closest("[data-tab]");
  if (!b) return;
  switchTab(b.dataset.tab);
});
function switchTab(tab){
  currentTab = tab;
  document.querySelectorAll("#mTabs [data-tab]").forEach(b => b.setAttribute("aria-current", b.dataset.tab === tab ? "page" : "false"));
  document.querySelectorAll(".mtab").forEach(p => { p.hidden = p.id !== "tab-" + tab; });
  if (tab === "browse") loadMarket();
  else if (tab === "mine") loadMine();
  else if (tab === "bids") loadBids();
  else if (tab === "won") loadWon();
  else if (tab === "history") loadHistory();
}

/* ===== Parcourir ===== */
let browseData = [];
let browseTopBids = {};
let mSearch = "";
let mRarity = null;
let mSort = "recent";
const SORT_LABELS = { recent: "Récemment listées", lowest: "Mise la plus basse", highest: "Mise la plus haute", ending: "Fin imminente" };

async function loadMarket(){
  document.getElementById("marketStatus").textContent = "Chargement…";
  await resolveExpiredAuctions();

  const { data, error } = await supabaseClient
    .from("market_listings")
    .select("id, seller_type, seller_profile_id, bot_name, listing_type, shiny, price, status, ends_at, created_at, card_id, card_catalogue(" + CARD_FIELDS + ")")
    .eq("status", "active")
    .order("created_at", { ascending: false });
  if (error){ document.getElementById("marketStatus").textContent = "Erreur : " + error.message; return; }

  browseData = data;
  browseTopBids = await topBidsFor(data.filter(r => r.listing_type === "auction").map(r => r.id));
  await resolveProfileNames(data.filter(r => r.seller_type === "player").map(r => r.seller_profile_id));
  await loadOwnedSet();

  renderBrowse();
}

function currentPrice(row){
  return row.listing_type === "auction" ? (browseTopBids[row.id] || row.price) : row.price;
}

function renderBrowse(){
  let list = browseData.filter(row => {
    const g = row.card_catalogue;
    if (mRarity !== null && g.rarity !== mRarity) return false;
    if (mSearch && !g.title.toLowerCase().includes(mSearch)) return false;
    return true;
  });

  if (mSort === "lowest") list = list.slice().sort((a, b) => currentPrice(a) - currentPrice(b));
  else if (mSort === "highest") list = list.slice().sort((a, b) => currentPrice(b) - currentPrice(a));
  else if (mSort === "ending") list = list.slice().sort((a, b) => {
    const ea = a.ends_at ? new Date(a.ends_at).getTime() : Infinity;
    const eb = b.ends_at ? new Date(b.ends_at).getTime() : Infinity;
    return ea - eb;
  });
  // "recent" garde l'ordre déjà trié par created_at desc côté requête.

  document.getElementById("marketStatus").textContent = list.length
    ? (list.length + " annonce" + (list.length > 1 ? "s" : "") + " active" + (list.length > 1 ? "s" : "") + ".")
    : "Aucune annonce ne correspond.";

  document.getElementById("marketGrid").innerHTML = list.length ? list.map(row => {
    const g = row.card_catalogue;
    const mine = row.seller_profile_id === session.user.id;
    const isAuction = row.listing_type === "auction";
    return marketTileHTML(g, row.shiny, row.id, {
      owned: !!ownedSet[row.card_id + "|" + (row.shiny ? 1 : 0)],
      leftLabel: isAuction ? (browseTopBids[row.id] ? "Mise actuelle" : "Mise de départ") : "Prix",
      leftValueHTML: coinsInline(currentPrice(row)),
      leftAccent: true,
      rightLabel: isAuction ? "Durée" : null,
      rightValueHTML: isAuction ? esc(formatTimeLeft(row.ends_at)) : "",
      rightUrgent: true,
      seller: mine ? null : sellerLabel(row),
    });
  }).join("") : '<p class="empty">Aucune annonce ne correspond à ces filtres.</p>';
}

document.getElementById("mSearch").addEventListener("input", (e) => {
  mSearch = e.target.value.trim().toLowerCase();
  renderBrowse();
});

document.getElementById("mRarTabs").innerHTML = RARITY_ORDER.map((_, i) => i).reverse().map(i => {
  const r = RARITY_ORDER[i];
  return '<button type="button" data-rar="' + i + '" style="--rc:' + r.color + '" aria-pressed="false" title="' + esc(r.name) + '">' + esc(r.abbr) + '</button>';
}).join("");
document.getElementById("mRarTabs").addEventListener("click", (e) => {
  const b = e.target.closest("[data-rar]");
  if (!b) return;
  const i = +b.dataset.rar;
  mRarity = mRarity === i ? null : i;
  document.querySelectorAll("#mRarTabs button").forEach(x => x.setAttribute("aria-pressed", String(+x.dataset.rar === mRarity)));
  renderBrowse();
});

const ddSort = setupDropdown("ddSort");
ddSort.panel.innerHTML = Object.keys(SORT_LABELS).map(k => '<button type="button" class="dd-opt' + (k === mSort ? " sel" : "") + '" data-value="' + k + '">' + esc(SORT_LABELS[k]) + '</button>').join("");
ddSort.panel.addEventListener("click", (e) => {
  const b = e.target.closest("[data-value]");
  if (!b) return;
  mSort = b.dataset.value;
  ddSort.label.textContent = SORT_LABELS[mSort];
  ddSort.panel.querySelectorAll(".dd-opt").forEach(o => o.classList.toggle("sel", o.dataset.value === mSort));
  closeAllDropdowns();
  renderBrowse();
});

/* ===== Mes ventes ===== */
let mySellableCards = [];

async function loadMySellableCards(){
  const { data } = await supabaseClient
    .from("collection")
    .select("card_id, shiny, count, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id);
  mySellableCards = data || [];
  const sel = document.getElementById("sellCard");
  const options = mySellableCards.map(row => {
    const g = row.card_catalogue;
    const label = (g ? g.title : row.card_id) + (row.shiny ? " ✦ brillante" : "") + " (×" + row.count + ")";
    return '<option value="' + esc(row.card_id) + '|' + (row.shiny ? 1 : 0) + '">' + esc(label) + '</option>';
  }).join("");
  sel.innerHTML = options || '<option value="">Aucune carte à vendre</option>';
}

document.getElementById("toggleSellForm").addEventListener("click", async () => {
  const form = document.getElementById("sellForm");
  form.hidden = !form.hidden;
  if (!form.hidden) await loadMySellableCards();
});

document.getElementById("sellType").addEventListener("change", (e) => {
  const isAuction = e.target.value === "auction";
  document.getElementById("sellPriceLabel").childNodes[0].textContent = isAuction ? "Mise de départ (pièces)" : "Prix (pièces)";
  document.getElementById("sellDurationRow").hidden = !isAuction;
});

document.getElementById("sellBtn").addEventListener("click", async () => {
  const raw = document.getElementById("sellCard").value || "";
  const parts = raw.split("|");
  const cardId = parts[0];
  const shinyFlag = parts[1];
  const type = document.getElementById("sellType").value;
  const price = parseInt(document.getElementById("sellPrice").value, 10);
  if (!cardId){ showMsg("sellMsg", "Choisis une carte.", "error"); return; }
  if (!price || price < 1){ showMsg("sellMsg", "Indique un prix valide.", "error"); return; }

  let error;
  if (type === "auction"){
    const duration = parseInt(document.getElementById("sellDuration").value, 10);
    ({ error } = await supabaseClient.rpc("create_auction_listing", {
      p_card_id: cardId, p_shiny: shinyFlag === "1", p_start_price: price, p_duration_minutes: duration,
    }));
  } else {
    ({ error } = await supabaseClient.rpc("create_sale_listing", {
      p_card_id: cardId, p_shiny: shinyFlag === "1", p_price: price,
    }));
  }
  if (error){ showMsg("sellMsg", error.message, "error"); return; }
  showMsg("sellMsg", "Annonce créée.", "ok");
  document.getElementById("sellPrice").value = "";
  document.getElementById("sellForm").hidden = true;
  await loadMine();
});

async function loadMine(){
  document.getElementById("mineStatus").textContent = "Chargement…";
  await resolveExpiredAuctions();

  const { data, error } = await supabaseClient
    .from("market_listings")
    .select("id, listing_type, shiny, price, ends_at, card_id, card_catalogue(" + CARD_FIELDS + ")")
    .eq("seller_profile_id", session.user.id)
    .eq("status", "active")
    .order("created_at", { ascending: false });
  if (error){ document.getElementById("mineStatus").textContent = "Erreur : " + error.message; return; }

  const top = await topBidsFor(data.filter(r => r.listing_type === "auction").map(r => r.id));
  document.getElementById("ctMine").textContent = data.length ? "(" + data.length + ")" : "";
  document.getElementById("mineStatus").textContent = data.length
    ? (data.length + " annonce" + (data.length > 1 ? "s" : "") + " active" + (data.length > 1 ? "s" : "") + ".")
    : "Aucune annonce active — mets une carte en vente ci-dessus.";

  document.getElementById("mineGrid").innerHTML = data.length ? data.map(row => {
    const g = row.card_catalogue;
    const isAuction = row.listing_type === "auction";
    return marketTileHTML(g, row.shiny, row.id, {
      leftLabel: isAuction ? (top[row.id] ? "Mise actuelle" : "Mise de départ") : "Prix",
      leftValueHTML: coinsInline(isAuction ? (top[row.id] || row.price) : row.price),
      leftAccent: true,
      rightLabel: isAuction ? "Durée" : null,
      rightValueHTML: isAuction ? esc(formatTimeLeft(row.ends_at)) : "",
      rightUrgent: true,
    });
  }).join("") : "";
}

/* ===== Mes enchères ===== */
async function loadBids(){
  await resolveExpiredAuctions();
  const { data } = await supabaseClient
    .from("market_bids")
    .select("listing_id, amount")
    .eq("bidder_profile_id", session.user.id)
    .order("amount", { ascending: false });

  const myTopByListing = {};
  (data || []).forEach(b => { if (!(b.listing_id in myTopByListing)) myTopByListing[b.listing_id] = b.amount; });
  const listingIds = Object.keys(myTopByListing);

  if (!listingIds.length){
    document.getElementById("ctBids").textContent = "";
    document.getElementById("bidsGrid").innerHTML =
      '<div class="mempty2"><span class="micon">📌</span>Vous n\'êtes en lice sur aucune enchère.</div>';
    return;
  }

  const { data: listings } = await supabaseClient
    .from("market_listings")
    .select("id, shiny, ends_at, status, seller_type, seller_profile_id, bot_name, card_id, card_catalogue(" + CARD_FIELDS + ")")
    .in("id", listingIds)
    .eq("status", "active");

  if (!listings || !listings.length){
    document.getElementById("ctBids").textContent = "";
    document.getElementById("bidsGrid").innerHTML =
      '<div class="mempty2"><span class="micon">📌</span>Vous n\'êtes en lice sur aucune enchère.</div>';
    return;
  }

  const top = await topBidsFor(listings.map(r => r.id));
  await resolveProfileNames(listings.filter(r => r.seller_type === "player").map(r => r.seller_profile_id));
  document.getElementById("ctBids").textContent = "(" + listings.length + ")";

  document.getElementById("bidsGrid").innerHTML = listings.map(row => {
    const g = row.card_catalogue;
    const leading = top[row.id] === myTopByListing[row.id];
    return marketTileHTML(g, row.shiny, row.id, {
      statusBadge: '<span class="badge ' + (leading ? "owned" : "outbid") + '">' + (leading ? "En tête" : "Surenchéri") + '</span>',
      leftLabel: "Ta mise",
      leftValueHTML: coinsInline(myTopByListing[row.id]),
      leftAccent: true,
      rightLabel: "Mise actuelle",
      rightValueHTML: coinsInline(top[row.id] || 0),
      seller: sellerLabel(row),
    });
  }).join("");
}

/* ===== Gagnées ===== */
async function loadWon(){
  document.getElementById("wonStatus").textContent = "Chargement…";
  const { data, error } = await supabaseClient
    .from("market_listings")
    .select("id, listing_type, shiny, price, seller_type, seller_profile_id, bot_name, card_id, card_catalogue(" + CARD_FIELDS + ")")
    .eq("buyer_profile_id", session.user.id)
    .eq("status", "sold")
    .order("created_at", { ascending: false });
  if (error){ document.getElementById("wonStatus").textContent = "Erreur : " + error.message; return; }

  const auctionIds = data.filter(r => r.listing_type === "auction").map(r => r.id);
  const myWinningBids = {};
  if (auctionIds.length){
    const { data: bids } = await supabaseClient
      .from("market_bids")
      .select("listing_id, amount")
      .eq("bidder_profile_id", session.user.id)
      .in("listing_id", auctionIds)
      .order("amount", { ascending: false });
    (bids || []).forEach(b => { if (!(b.listing_id in myWinningBids)) myWinningBids[b.listing_id] = b.amount; });
  }
  await resolveProfileNames(data.filter(r => r.seller_type === "player").map(r => r.seller_profile_id));

  document.getElementById("ctWon").textContent = data.length ? "(" + data.length + ")" : "";
  document.getElementById("wonStatus").textContent = data.length
    ? (data.length + " carte" + (data.length > 1 ? "s" : "") + " acquise" + (data.length > 1 ? "s" : "") + " sur le marché.")
    : "Rien acheté ou gagné aux enchères pour l'instant.";

  document.getElementById("wonGrid").innerHTML = data.length ? data.map(row => {
    const g = row.card_catalogue;
    const paid = row.listing_type === "auction" ? (myWinningBids[row.id] || row.price) : row.price;
    return marketTileHTML(g, row.shiny, row.id, {
      owned: true,
      leftLabel: "Achetée pour",
      leftValueHTML: coinsInline(paid),
      leftAccent: true,
      seller: sellerLabel(row),
    });
  }).join("") : "";
}

/* ===== Historique ===== */
async function loadHistory(){
  document.getElementById("histStatus").textContent = "Chargement…";
  const { data, error } = await supabaseClient
    .from("market_listings")
    .select("id, listing_type, shiny, price, status, card_id, card_catalogue(" + CARD_FIELDS + ")")
    .eq("seller_profile_id", session.user.id)
    .in("status", ["sold", "cancelled"])
    .order("created_at", { ascending: false });
  if (error){ document.getElementById("histStatus").textContent = "Erreur : " + error.message; return; }

  const auctionIds = data.filter(r => r.listing_type === "auction").map(r => r.id);
  const maxBid = {};
  if (auctionIds.length){
    const { data: bids } = await supabaseClient
      .from("market_bids")
      .select("listing_id, amount")
      .in("listing_id", auctionIds)
      .order("amount", { ascending: false });
    (bids || []).forEach(b => { if (!(b.listing_id in maxBid)) maxBid[b.listing_id] = b.amount; });
  }
  const me = await getMyUsername();

  document.getElementById("ctHist").textContent = data.length ? "(" + data.length + ")" : "";
  document.getElementById("histStatus").textContent = data.length
    ? (data.length + " annonce" + (data.length > 1 ? "s" : "") + " terminée" + (data.length > 1 ? "s" : "") + ".")
    : "Aucune annonce terminée pour l'instant.";

  document.getElementById("historyGrid").innerHTML = data.length ? data.map(row => {
    const g = row.card_catalogue;
    const isAuction = row.listing_type === "auction";
    let label, price;
    if (row.status === "sold"){
      label = "Vendue pour";
      price = isAuction ? (maxBid[row.id] || row.price) : row.price;
    } else if (isAuction && maxBid[row.id]){
      label = "Annulée (mise invalidée)";
      price = maxBid[row.id];
    } else {
      label = "Non vendue";
      price = row.price;
    }
    return marketTileHTML(g, row.shiny, row.id, {
      leftLabel: label,
      leftValueHTML: coinsInline(price),
      leftAccent: true,
      rightLabel: "Durée",
      rightValueHTML: "Terminée",
      seller: me,
    });
  }).join("") : "";
}

(async function(){
  if (!(await initPage())) return;
  await loadMarket();
})();
