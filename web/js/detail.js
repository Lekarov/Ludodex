/* ===== Fiche détail d'une carte, partagée par "Ta collection" (possédée, compte réel > 0 :
   actions Mettre aux enchères / Défausser) et "Toutes les cartes" (compte omis ou 0 : bouton
   liste de souhaits à la place — pas de variante brillante hors collection, c'est une propriété
   d'exemplaire possédé, pas de la fiche catalogue). Onglets Détails / Marché ; le cours du marché
   est calculé sur les VRAIES ventes de tous les joueurs pour cette carte (market_listings), pas
   une simulation locale. */
let dtab = "info";
let detailCtx = null; // { cardId, shiny, game, count, wishlisted }

// Icônes de la fiche détail (gavel/trash), reprises de la bibliothèque open source Lucide
// (licence ISC) — ATK/DEF réutilisent ICON_SWORDS/ICON_SHIELD déjà définies dans render.js.
const ICON_GAVEL = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m14 13-8.381 8.38a1 1 0 0 1-3.001-3l8.384-8.381"></path><path d="m16 16 6-6"></path><path d="m21.5 10.5-8-8"></path><path d="m8 8 6-6"></path><path d="m8.5 7.5 8 8"></path></svg>';
const ICON_TRASH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 11v6"></path><path d="M14 11v6"></path><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"></path><path d="M3 6h18"></path><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>';
function statboxHTML(g){
  return '<div class="statbox">' +
    '<div class="atk"><b>' + ICON_SWORDS + fmt(g.atk) + '</b><span>ATK</span></div>' +
    '<div class="def"><b>' + ICON_SHIELD + fmt(g.def) + '</b><span>DEF</span></div>' +
  '</div>';
}

// Icône "drapeau" (signaler), même bibliothèque Lucide (ISC) que les autres icônes du fichier.
const ICON_FLAG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 8 2a6 6 0 0 1 3.6-1.2.7.7 0 0 1 .4.6v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 15c-3 0-5-2-8-2a6 6 0 0 0-4 1.5"></path></svg>';
// Signalement d'image cassée par un joueur (065_card_image_requests.sql, report_card_image()) —
// remonte prioritairement dans la file de triage du hub. Formulaire inline, jamais de prompt()
// natif (retour Doktor 29/09/2026 : ces popups cassent le visuel).
function imageReportHTML(){
  return '<div class="imgreport">' +
    '<button class="imgreport-btn" type="button" id="detailImgReportBtn" title="Signaler un problème avec cette image">' + ICON_FLAG + ' Signaler l\'image</button>' +
    '<div class="imgreport-form" id="detailImgReportForm" hidden>' +
      '<input type="text" id="detailImgReportComment" placeholder="Précise le problème (optionnel)">' +
      '<button class="btn" type="button" id="detailImgReportSend">Envoyer</button>' +
    '</div>' +
  '</div>';
}
function wireImageReport(cardId){
  const btn = document.getElementById("detailImgReportBtn");
  const form = document.getElementById("detailImgReportForm");
  if (!btn || !form) return;
  btn.addEventListener("click", () => { form.hidden = !form.hidden; });
  document.getElementById("detailImgReportSend").addEventListener("click", async () => {
    const comment = document.getElementById("detailImgReportComment").value.trim() || null;
    const { error } = await supabaseClient.rpc("report_card_image", { p_card_id: cardId, p_comment: comment });
    if (error){ toast(error.message); return; }
    toast("Merci, l'image a été signalée à l'équipe.");
    form.hidden = true;
    btn.disabled = true;
    btn.textContent = "Image signalée";
  });
}

async function openDetail(cardId, shiny, game, count){
  detailCtx = { cardId, shiny: !!shiny, game, count: count || 0, wishlisted: false, tags: [] };
  dtab = "info";
  renderDetail();
  const dlg = document.getElementById("cardDlg");
  if (!dlg.open) dlg.showModal();
  dlg.scrollTop = 0;

  // Liste de souhaits : n'existe que pour les jeux (wishlist.card_id référence card_catalogue,
  // pas character_catalogue — voir 037_wishlist.sql). Pas de requête pour un personnage.
  if (!detailCtx.count && game.kind !== "character"){
    const { data } = await supabaseClient
      .from("wishlist").select("card_id")
      .eq("profile_id", session.user.id).eq("card_id", cardId).maybeSingle();
    if (detailCtx.cardId !== cardId) return; // une autre carte a été ouverte entre-temps
    detailCtx.wishlisted = !!data;
    if (dtab === "info") renderDetail();
  }

  // Tags : marche pour un jeu comme pour un personnage (voir 051_card_tags.sql, pas de FK vers
  // card_catalogue — all_cards_catalogue mélange deux tables sous le même card_id).
  const { data: tagRows } = await supabaseClient
    .from("card_tags").select("tag")
    .eq("profile_id", session.user.id).eq("card_id", cardId)
    .order("created_at", { ascending: true });
  if (detailCtx.cardId !== cardId) return;
  detailCtx.tags = (tagRows || []).map(r => r.tag);
  if (dtab === "info") renderDetail();
}

// Tags déjà utilisés par le joueur, toutes cartes confondues — suggestions du champ d'ajout
// (datalist native, pas de dropdown maison nécessaire pour une simple autocomplétion).
let tagSuggestionsCache = null;
async function loadTagSuggestions(){
  if (tagSuggestionsCache) return tagSuggestionsCache;
  const { data } = await supabaseClient
    .from("card_tags").select("tag")
    .eq("profile_id", session.user.id)
    .limit(500);
  tagSuggestionsCache = [...new Set((data || []).map(r => r.tag))].sort();
  return tagSuggestionsCache;
}

async function addTag(rawTag){
  const tag = rawTag.trim();
  if (!tag || detailCtx.tags.some(t => t.toLowerCase() === tag.toLowerCase())) return;
  const { cardId } = detailCtx;
  detailCtx.tags.push(tag);
  renderDetail();
  const { error } = await supabaseClient.from("card_tags").insert({ profile_id: session.user.id, card_id: cardId, tag });
  if (error && detailCtx.cardId === cardId){
    detailCtx.tags = detailCtx.tags.filter(t => t !== tag);
    toast(error.message);
    renderDetail();
    return;
  }
  tagSuggestionsCache = null; // invalidé : un nouveau tag est peut-être apparu
}

async function removeTag(tag){
  const { cardId } = detailCtx;
  detailCtx.tags = detailCtx.tags.filter(t => t !== tag);
  renderDetail();
  await supabaseClient.from("card_tags").delete()
    .eq("profile_id", session.user.id).eq("card_id", cardId).eq("tag", tag);
}

async function toggleWishlist(){
  const { cardId, wishlisted } = detailCtx;
  const btn = document.getElementById("detailWishBtn");
  if (btn) btn.disabled = true;
  if (wishlisted){
    const { error } = await supabaseClient.from("wishlist").delete()
      .eq("profile_id", session.user.id).eq("card_id", cardId);
    if (error){ toast(error.message); if (btn) btn.disabled = false; return; }
    detailCtx.wishlisted = false;
    toast("Retirée de ta liste de souhaits.");
  } else {
    const { error } = await supabaseClient.from("wishlist").insert({ profile_id: session.user.id, card_id: cardId });
    if (error){ toast(error.message); if (btn) btn.disabled = false; return; }
    detailCtx.wishlisted = true;
    toast("Ajoutée à ta liste de souhaits — tu seras alerté si elle est mise en vente.");
  }
  renderDetail();
  if (typeof onWishlistChanged === "function") onWishlistChanged(cardId, detailCtx.wishlisted);
}

// Bio : français si dispo, sinon anglais (marqué EN), sinon repli sur le style/genre IGDB
// (ex. "Shooter, Indie, Arcade") — beaucoup de jeux n'ont aucun résumé IGDB, voir
// 036_card_catalogue_descriptions.sql. Jamais vide silencieusement : au moins le genre si connu.
function bioHTML(g){
  if (g.description_fr) return '<p class="ddesc">' + esc(g.description_fr) + '</p>';
  if (g.description_en) return '<p class="ddesc">' + esc(g.description_en) + ' <span class="ddesc-lang">(EN)</span></p>';
  if (g.genres) return '<p class="ddesc ddesc-genres">' + esc(g.genres) + '</p>';
  return '<p class="ddesc unavailable">Description indisponible.</p>';
}

// Palette de teintes vives et "appréciées" — l'assignation est déterministe (hash du texte du
// tag), donc définitive : un même tag garde toujours la même couleur, partout, sans avoir besoin
// de la stocker en base. Rendu façon WikiMasters (voir tagsHTML ci-dessous) : la teinte sert de
// TEINTURE translucide (fond ~22% + bord ~50% via color-mix), pas de fond plein — donc on part de
// couleurs vives (Tailwind *-400) plutôt que de pastels clairs, sans quoi la teinture serait trop
// pâle une fois diluée sur le fond sombre.
const TAG_PALETTE = [
  "#818cf8", "#38bdf8", "#34d399", "#fb7185", "#fbbf24",
  "#a78bfa", "#2dd4bf", "#f472b6", "#fb923c", "#a3e635",
];
function tagColor(tag){
  let hash = 0;
  for (let i = 0; i < tag.length; i++) hash = (hash * 31 + tag.charCodeAt(i)) >>> 0;
  return TAG_PALETTE[hash % TAG_PALETTE.length];
}

function tagsHTML(){
  const tags = detailCtx.tags;
  return '<div class="tagbox">' +
    '<p class="mlabel">Tags</p>' +
    (tags.length
      ? '<div class="tagchips">' + tags.map(t => {
          const c = tagColor(t);
          const style = 'background:color-mix(in srgb,' + c + ' 22%,transparent);' +
            'border-color:color-mix(in srgb,' + c + ' 55%,transparent)';
          return '<span class="chip" style="' + style + '">' + esc(t) + '<button type="button" data-rmtag="' + esc(t) + '" aria-label="Retirer le tag ' + esc(t) + '">×</button></span>';
        }).join('') + '</div>'
      : '') +
    '<input class="taginput" id="tagInput" type="text" maxlength="24" placeholder="Ajouter un tag…" list="tagSuggestions" autocomplete="off">' +
    '<datalist id="tagSuggestions"></datalist>' +
  '</div>';
}
function fillTagSuggestions(){
  loadTagSuggestions().then((tags) => {
    const dl = document.getElementById("tagSuggestions");
    if (dl) dl.innerHTML = tags.map(t => '<option value="' + esc(t) + '">').join('');
  });
}

function renderDetail(){
  const { shiny, game: g, count, wishlisted } = detailCtx;
  const owned = count > 0;
  const sub = [g.developer ? esc(g.developer) : null, esc(g.platform_name), g.year].filter(Boolean).join(" · ");

  // Personnage (character_catalogue, via la vue all_cards_catalogue) : pas de possession, pas de
  // marché, pas de liste de souhaits — juste la fiche. Un seul onglet, pas de sélecteur Détails/
  // Marché (rien à y mettre).
  if (g.kind === "character"){
    document.getElementById("dlgBody").innerHTML =
      '<h3>' + esc(g.title) + '</h3>' +
      '<span class="pill" style="--rc:' + g.rarity_color + '">' + esc(g.rarity_name) + '</span>' +
      '<p class="dsub">' + sub + '</p>' +
      '<div class="det">' +
        '<div class="cw">' + cardHTML(g, {}) + '</div>' +
        '<div>' +
          bioHTML(g) +
          tagsHTML() +
          statboxHTML(g) +
          imageReportHTML() +
        '</div>' +
      '</div>';
    fillTagSuggestions();
    wireImageReport(detailCtx.cardId);
    return;
  }

  const actionsHTML = owned
    ? '<div class="actions start">' +
        '<button class="btn primary" type="button" id="detailAuctionBtn">' + ICON_GAVEL + 'Vendre</button>' +
        '<button class="btn" type="button" id="detailDiscardBtn">' + ICON_TRASH + 'Défausser' + (count > 1 ? ' <span class="countbadge">+' + fmt(count - 1) + '</span>' : '') + '</button>' +
      '</div>'
    : '<button class="wishtoggle" type="button" id="detailWishBtn" aria-pressed="' + (wishlisted ? "true" : "false") + '" aria-label="Liste de souhaits" title="Liste de souhaits">' +
        (wishlisted ? "★" : "☆") +
      '</button>' +
      '<p class="sub">Reçois une alerte si cette carte est mise en vente sur le marché.</p>';

  document.getElementById("dlgBody").innerHTML =
    '<div class="dhead"><h3>' + esc(g.title) + '</h3></div>' +
    '<div class="dmeta">' +
      '<span class="pill" style="--rc:' + g.rarity_color + '">' + esc(g.rarity_name) + (shiny ? ' <span class="shinymark">✦ brillante</span>' : '') + '</span>' +
      '<div class="seg det-vseg">' +
        '<button type="button" data-dtab="info" aria-pressed="' + (dtab === "info") + '">Détails</button>' +
        '<button type="button" data-dtab="market" aria-pressed="' + (dtab === "market") + '">Marché</button>' +
      '</div>' +
    '</div>' +
    '<p class="dsub">' + sub + '</p>' +
    '<div id="dtabInfo"' + (dtab === "info" ? "" : " hidden") + '><div class="det">' +
      '<div class="cw">' + cardHTML(g, { shiny: shiny, count: count }) + '</div>' +
      '<div>' +
        bioHTML(g) +
        tagsHTML() +
        statboxHTML(g) +
        actionsHTML +
        imageReportHTML() +
      '</div>' +
    '</div></div>' +
    '<div id="dtabMarket"' + (dtab === "market" ? "" : " hidden") + '><div class="dfull"><p class="sub">Chargement…</p></div></div>';
  if (dtab === "info") fillTagSuggestions();

  if (owned){
    document.getElementById("detailAuctionBtn").addEventListener("click", openSellDialog);
    document.getElementById("detailDiscardBtn").addEventListener("click", discardFromDetail);
  } else {
    document.getElementById("detailWishBtn").addEventListener("click", toggleWishlist);
  }
  if (dtab === "info") wireImageReport(detailCtx.cardId);
  if (dtab === "market") loadMarketStats();
}

document.getElementById("cardDlg").addEventListener("click", (e) => {
  if (e.target === document.getElementById("cardDlg")){ closeDetail(); return; }
  const rm = e.target.closest("[data-rmtag]");
  if (rm){ removeTag(rm.dataset.rmtag); return; }
  const t = e.target.closest("[data-dtab]");
  if (!t) return;
  dtab = t.dataset.dtab;
  renderDetail();
});
document.getElementById("cardDlg").addEventListener("keydown", (e) => {
  if (e.key !== "Enter" || e.target.id !== "tagInput") return;
  e.preventDefault();
  const val = e.target.value;
  e.target.value = "";
  addTag(val);
});
document.getElementById("dlgClose").addEventListener("click", closeDetail);
function closeDetail(){ document.getElementById("cardDlg").close(); }

async function discardFromDetail(){
  if (!confirm("Défausser cette carte contre des pièces ? Action définitive.")) return;
  const { cardId, shiny } = detailCtx;
  const { data, error } = await supabaseClient.rpc("discard_card", { p_card_id: cardId, p_shiny: shiny });
  if (error){ toast(error.message); return; }
  toast("+" + data + " pièces");
  closeDetail();
  await refreshHud();
  // loadCollection() n'existe que sur collection.html — depuis boosters.html (révélation), rien
  // à recharger sur place, le HUD (pièces) suffit.
  if (typeof loadCollection === "function") await loadCollection();
}

/* ===== Onglet Marché : cours réel calculé sur les ventes déjà résolues pour cette carte,
   tous joueurs confondus (market_listings status='sold' + market_bids pour les enchères
   gagnantes — même logique que market.js/loadHistory). ===== */
async function loadMarketStats(){
  const { cardId, shiny } = detailCtx;
  const box = document.getElementById("dtabMarket");

  const { data: sold, error } = await supabaseClient
    .from("market_listings")
    .select("id, listing_type, price, created_at")
    .eq("card_id", cardId).eq("shiny", shiny).eq("status", "sold")
    .order("created_at", { ascending: false })
    .limit(60);
  if (error){ box.innerHTML = '<div class="dfull"><p class="sub">Erreur : ' + esc(error.message) + '</p></div>'; return; }

  const auctionIds = sold.filter(r => r.listing_type === "auction").map(r => r.id);
  const winBid = {};
  if (auctionIds.length){
    const { data: bids } = await supabaseClient
      .from("market_bids").select("listing_id, amount")
      .in("listing_id", auctionIds).order("amount", { ascending: false });
    (bids || []).forEach(b => { if (!(b.listing_id in winBid)) winBid[b.listing_id] = b.amount; });
  }
  const prices = sold.map(r => r.listing_type === "auction" ? (winBid[r.id] || r.price) : r.price);

  if (!prices.length){
    box.innerHTML = '<div class="dfull"><p class="sub">Aucune vente pour l\'instant sur le marché pour cette carte' + (shiny ? " (brillante)" : "") + '.</p></div>';
    return;
  }

  const avg = Math.round(prices.reduce((a, b) => a + b, 0) / prices.length);
  const min = Math.min(...prices);
  const max = Math.max(...prices);

  box.innerHTML = '<div class="dfull">' +
    '<div class="hstats">' +
      '<div><span>Ventes</span><b>' + prices.length + '</b></div>' +
      '<div><span>Dernier</span><b>' + fmt(prices[0]) + '<span class="coin" aria-hidden="true"></span></b></div>' +
      '<div><span>Moyenne</span><b>' + fmt(avg) + '<span class="coin" aria-hidden="true"></span></b></div>' +
      '<div><span>Min</span><b>' + fmt(min) + '<span class="coin" aria-hidden="true"></span></b></div>' +
      '<div><span>Max</span><b>' + fmt(max) + '<span class="coin" aria-hidden="true"></span></b></div>' +
    '</div>' +
    '<h4>' + Math.min(10, prices.length) + ' dernières ventes</h4>' +
    '<ul class="sales">' + sold.slice(0, 10).map((r, i) => {
      const d = new Date(r.created_at).toLocaleDateString("fr-FR", { day: "2-digit", month: "short", year: "numeric" });
      return '<li><span>' + esc(d) + '</span><span>' + (r.listing_type === "auction" ? "Enchère" : "Vente directe") + '</span><b>' + fmt(prices[i]) + '<span class="coin" aria-hidden="true"></span></b></li>';
    }).join("") + '</ul>' +
  '</div>';
}

/* ===== Vendre depuis la fiche détail : vente directe OU enchère, façon WikiMasters (icône +
   titre/sous-titre en tête, mini-carte + stats de ventes réelles pour aider à fixer le prix,
   créneaux de durée élargis). Un seul dialogue, le type se bascule sans le refermer. ===== */
const SELL_DURATIONS = [10, 30, 60, 180, 360, 720]; // minutes : 10min/30min/1h/3h/6h/12h
function durLabel(m){ return m < 60 ? m + " min" : (m / 60) + " h"; }

function openSellDialog(){
  const { cardId, shiny, game: g } = detailCtx;
  let type = "auction";
  let duration = 60;
  let amount = 10;

  function render(){
    const isAuction = type === "auction";
    const title = isAuction ? "Mettre aux enchères" : "Vendre directement";
    const sub = isAuction
      ? "Un exemplaire sera mis en réserve pour la durée de l'enchère."
      : "Un exemplaire sera mis en réserve jusqu'à l'achat par un autre joueur, ou jusqu'à annulation.";
    const priceLabel = isAuction ? "Mise de départ" : "Prix";
    const launchLabel = isAuction ? "Lancer l'enchère" : "Mettre en vente";

    document.getElementById("auctionDlgBody").innerHTML =
      '<div class="selldlg-head">' + ICON_GAVEL + '<div><h3>' + esc(title) + '</h3><p class="dsub">' + esc(sub) + '</p></div></div>' +
      '<div class="seg selltype" id="sellTypeSeg">' +
        '<button type="button" data-selltype="sale" aria-pressed="' + (!isAuction) + '">Vente directe</button>' +
        '<button type="button" data-selltype="auction" aria-pressed="' + isAuction + '">Enchère</button>' +
      '</div>' +
      '<div class="sellsummary">' +
        '<div class="cw">' + cardHTML(g, { shiny: shiny }) + '</div>' +
        '<div class="sellsummary-info">' +
          '<p class="sellname">' + esc(g.title) + '</p>' +
          '<p class="mlabel" style="margin:.2rem 0 .6rem">Marché · ' + esc(g.rarity_name) + '</p>' +
          '<div id="sellStats"><p class="sub" style="margin:0">Chargement…</p></div>' +
        '</div>' +
      '</div>' +
      '<div class="mlabel" style="margin:1rem 0 .35rem">' + esc(priceLabel) + '</div>' +
      '<div class="stepper">' +
        '<button type="button" id="stepMinus" aria-label="Diminuer">−</button>' +
        '<input type="text" id="auctionAmount" inputmode="numeric" value="' + amount + '">' +
        '<button type="button" id="stepPlus" aria-label="Augmenter">+</button>' +
      '</div>' +
      (isAuction
        ? '<div class="mlabel" style="margin:.9rem 0 .35rem">Durée</div>' +
          '<div class="durbtns" id="durBtns">' +
            SELL_DURATIONS.map(m => '<button type="button" data-dur="' + m + '" aria-pressed="' + (m === duration) + '">' + durLabel(m) + '</button>').join("") +
          '</div>'
        : "") +
      '<div class="msg" id="auctionMsg"></div>' +
      '<div class="actions">' +
        '<button class="btn" type="button" id="auctionCancelBtn">Annuler</button>' +
        '<button class="btn primary" type="button" id="auctionLaunchBtn">' + esc(launchLabel) + '</button>' +
      '</div>';

    document.getElementById("sellTypeSeg").addEventListener("click", (e) => {
      const b = e.target.closest("[data-selltype]");
      if (!b || b.dataset.selltype === type) return;
      amount = parseInt(document.getElementById("auctionAmount").value, 10) || amount;
      type = b.dataset.selltype;
      render();
    });

    const amountInput = document.getElementById("auctionAmount");
    document.getElementById("stepMinus").addEventListener("click", () => {
      amountInput.value = Math.max(1, (parseInt(amountInput.value, 10) || 1) - 5);
    });
    document.getElementById("stepPlus").addEventListener("click", () => {
      amountInput.value = (parseInt(amountInput.value, 10) || 0) + 5;
    });
    if (isAuction){
      document.getElementById("durBtns").addEventListener("click", (e) => {
        const b = e.target.closest("[data-dur]");
        if (!b) return;
        duration = +b.dataset.dur;
        document.querySelectorAll("#durBtns [data-dur]").forEach(x => x.setAttribute("aria-pressed", String(+x.dataset.dur === duration)));
      });
    }
    document.getElementById("auctionCancelBtn").addEventListener("click", () => document.getElementById("auctionDlg").close());
    document.getElementById("auctionLaunchBtn").addEventListener("click", async () => {
      const value = parseInt(amountInput.value, 10);
      if (!value || value < 1){ showMsg("auctionMsg", "Indique un montant valide.", "error"); return; }
      const rpc = isAuction ? "create_auction_listing" : "create_sale_listing";
      const params = isAuction
        ? { p_card_id: cardId, p_shiny: shiny, p_start_price: value, p_duration_minutes: duration }
        : { p_card_id: cardId, p_shiny: shiny, p_price: value };
      const { error } = await supabaseClient.rpc(rpc, params);
      if (error){ showMsg("auctionMsg", error.message, "error"); return; }
      toast(isAuction ? "Enchère lancée." : "Mise en vente effectuée.");
      document.getElementById("auctionDlg").close();
      closeDetail();
      if (typeof loadCollection === "function") await loadCollection();
    });

    loadSellStats(cardId, shiny);
  }

  render();
  const dlg = document.getElementById("auctionDlg");
  if (!dlg.open) dlg.showModal();
}

// Ventes réelles déjà résolues pour cette carte (même logique que loadMarketStats), condensées
// en 3 chiffres dans le dialogue de vente pour aider à fixer un prix cohérent avec le marché.
async function loadSellStats(cardId, shiny){
  const { data: sold } = await supabaseClient
    .from("market_listings")
    .select("id, listing_type, price")
    .eq("card_id", cardId).eq("shiny", shiny).eq("status", "sold")
    .order("created_at", { ascending: false })
    .limit(30);
  const box = document.getElementById("sellStats");
  if (!box) return; // dialogue refermé ou type changé entre-temps
  if (!sold || !sold.length){
    box.innerHTML = '<p class="sub" style="margin:0">Pas encore de vente pour cette carte.</p>';
    return;
  }
  const auctionIds = sold.filter(r => r.listing_type === "auction").map(r => r.id);
  const winBid = {};
  if (auctionIds.length){
    const { data: bids } = await supabaseClient
      .from("market_bids").select("listing_id, amount")
      .in("listing_id", auctionIds).order("amount", { ascending: false });
    (bids || []).forEach(b => { if (!(b.listing_id in winBid)) winBid[b.listing_id] = b.amount; });
  }
  const prices = sold.map(r => r.listing_type === "auction" ? (winBid[r.id] || r.price) : r.price);
  const avg = Math.round(prices.reduce((a, b) => a + b, 0) / prices.length);
  box.innerHTML =
    '<div class="sellstat"><span>Ventes</span><b>' + prices.length + '</b></div>' +
    '<div class="sellstat"><span>Dernière</span><b>' + fmt(prices[0]) + '<span class="coin" aria-hidden="true"></span></b></div>' +
    '<div class="sellstat"><span>Moyenne</span><b>' + fmt(avg) + '<span class="coin" aria-hidden="true"></span></b></div>';
}
// Le dialogue d'enchère n'existe que sur les pages qui affichent des cartes possédées
// (collection.html) — absent sur cards.html (parcourt tout le catalogue, jamais d'enchère
// possible depuis là), donc ces éléments peuvent ne pas exister ici.
const auctionDlgEl = document.getElementById("auctionDlg");
if (auctionDlgEl){
  document.getElementById("auctionDlgClose").addEventListener("click", () => auctionDlgEl.close());
  auctionDlgEl.addEventListener("click", (e) => {
    if (e.target === auctionDlgEl) auctionDlgEl.close();
  });
}
