/* Échanges joueur-à-joueur — propose_trade/respond_trade/cancel_trade (033_rpc_trades.sql).
   offered/requested sont des tableaux [{card_id, shiny, count}] : construits ici depuis les
   sélecteurs, envoyés tels quels au serveur qui revalide tout (les RPC ne font confiance à rien
   de ce que le client affirme posséder). */

const cardCache = {}; // card_id -> row card_catalogue (pour l'affichage des miniatures)
async function resolveCards(ids){
  const missing = [...new Set(ids)].filter(id => id && !(id in cardCache));
  if (!missing.length) return;
  const { data } = await supabaseClient.from("card_catalogue").select("card_id, " + CARD_FIELDS).in("card_id", missing);
  (data || []).forEach(c => { cardCache[c.card_id] = c; });
}
function chipLabel(item){
  const g = cardCache[item.card_id];
  const title = g ? g.title : item.card_id;
  return title + (item.shiny ? " ✦" : "") + (item.count > 1 ? " ×" + item.count : "");
}
function miniHTML(items){
  if (!items.length) return '<span class="tnone">—</span>';
  return items.map(it => {
    const g = cardCache[it.card_id];
    return g ? thumbHTML(g, it.shiny) : '<span class="thumb" title="' + esc(it.card_id) + '">?</span>';
  }).join("");
}

let myCollection = []; // [{card_id, shiny, count, card_catalogue}]
let offerItems = [];
let targetProfile = null; // { id, username }
let targetCollection = [];
let requestItems = [];

async function loadMyCollection(){
  const { data } = await supabaseClient
    .from("collection")
    .select("card_id, shiny, count, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id);
  myCollection = data || [];
  const sel = document.getElementById("offerCard");
  sel.innerHTML = myCollection.length ? myCollection.map(row => {
    const g = row.card_catalogue;
    const label = (g ? g.title : row.card_id) + (row.shiny ? " ✦" : "") + " (×" + row.count + ")";
    return '<option value="' + esc(row.card_id) + '|' + (row.shiny ? 1 : 0) + '">' + esc(label) + '</option>';
  }).join("") : '<option value="">Aucune carte à proposer</option>';
}

document.getElementById("loadTargetBtn").addEventListener("click", async () => {
  const username = document.getElementById("targetUsername").value.trim();
  if (!username){ showMsg("targetMsg", "Indique un pseudo.", "error"); return; }

  const { data, error } = await supabaseClient
    .from("profiles").select("id, username, collection_public")
    .ilike("username", username).limit(1);
  if (error){ showMsg("targetMsg", error.message, "error"); return; }
  if (!data || !data.length){ showMsg("targetMsg", "Aucun joueur avec ce pseudo.", "error"); return; }
  if (data[0].id === session.user.id){ showMsg("targetMsg", "C'est toi-même.", "error"); return; }

  targetProfile = data[0];
  offerItems = []; requestItems = [];
  document.getElementById("targetMsg").className = "msg";
  document.getElementById("targetName").textContent = targetProfile.username;
  document.getElementById("tradeBuilder").hidden = false;
  renderChips();

  const { data: coll } = await supabaseClient
    .from("collection")
    .select("card_id, shiny, count, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", targetProfile.id);
  targetCollection = coll || [];
  const sel = document.getElementById("requestCard");
  const note = document.getElementById("targetCollectionNote");
  if (!targetProfile.collection_public){
    sel.innerHTML = '<option value="">Collection privée</option>';
    note.textContent = targetProfile.username + " n'a pas rendu sa collection publique : tu ne peux pas voir ce qu'il possède.";
  } else if (!targetCollection.length){
    sel.innerHTML = '<option value="">Collection vide</option>';
    note.textContent = "";
  } else {
    sel.innerHTML = targetCollection.map(row => {
      const g = row.card_catalogue;
      const label = (g ? g.title : row.card_id) + (row.shiny ? " ✦" : "") + " (×" + row.count + ")";
      return '<option value="' + esc(row.card_id) + '|' + (row.shiny ? 1 : 0) + '">' + esc(label) + '</option>';
    }).join("");
    note.textContent = "";
  }
});

function addItem(list, source, cardSelectId, qtyId){
  const raw = document.getElementById(cardSelectId).value || "";
  const parts = raw.split("|");
  const cardId = parts[0];
  const shiny = parts[1] === "1";
  if (!cardId) return null;
  const qty = Math.max(1, parseInt(document.getElementById(qtyId).value, 10) || 1);
  const owned = source.find(r => r.card_id === cardId && !!r.shiny === shiny);
  const maxQty = owned ? owned.count : 1;
  const existing = list.find(it => it.card_id === cardId && it.shiny === shiny);
  const newQty = Math.min(maxQty, (existing ? existing.count : 0) + qty);
  if (existing) existing.count = newQty;
  else list.push({ card_id: cardId, shiny, count: newQty });
  return true;
}

document.getElementById("offerAddBtn").addEventListener("click", async () => {
  if (addItem(offerItems, myCollection, "offerCard", "offerQty")){
    await resolveCards(offerItems.map(i => i.card_id));
    renderChips();
  }
});
document.getElementById("requestAddBtn").addEventListener("click", async () => {
  if (addItem(requestItems, targetCollection, "requestCard", "requestQty")){
    await resolveCards(requestItems.map(i => i.card_id));
    renderChips();
  }
});

function renderChipList(elId, items){
  const el = document.getElementById(elId);
  el.innerHTML = items.length ? items.map((it, i) =>
    '<span class="tradechip">' + esc(chipLabel(it)) + '<button class="rm" type="button" data-list="' + elId + '" data-i="' + i + '" aria-label="Retirer">×</button></span>'
  ).join("") : '<span class="tnone">Aucune carte ajoutée.</span>';
}
function renderChips(){
  renderChipList("offerChips", offerItems);
  renderChipList("requestChips", requestItems);
}
document.getElementById("offerChips").addEventListener("click", (e) => {
  const b = e.target.closest("[data-i]"); if (!b) return;
  offerItems.splice(+b.dataset.i, 1); renderChips();
});
document.getElementById("requestChips").addEventListener("click", (e) => {
  const b = e.target.closest("[data-i]"); if (!b) return;
  requestItems.splice(+b.dataset.i, 1); renderChips();
});

document.getElementById("sendTradeBtn").addEventListener("click", async () => {
  if (!targetProfile){ return; }
  if (!offerItems.length || !requestItems.length){
    showMsg("sendTradeMsg", "Ajoute au moins une carte de chaque côté.", "error"); return;
  }
  const { error } = await supabaseClient.rpc("propose_trade", {
    p_to_profile: targetProfile.id,
    p_offered: offerItems.map(({ card_id, shiny, count }) => ({ card_id, shiny, count })),
    p_requested: requestItems.map(({ card_id, shiny, count }) => ({ card_id, shiny, count })),
  });
  if (error){ showMsg("sendTradeMsg", error.message, "error"); return; }
  showMsg("sendTradeMsg", "Proposition envoyée.", "ok");
  offerItems = []; requestItems = [];
  renderChips();
  await loadMyCollection();
  await loadTab(currentTab);
});

/* ===== Onglets ===== */
let currentTab = "received";
document.getElementById("trTabs").addEventListener("click", (e) => {
  const b = e.target.closest("[data-tab]"); if (!b) return;
  currentTab = b.dataset.tab;
  document.querySelectorAll("#trTabs [data-tab]").forEach(x => x.setAttribute("aria-pressed", x.dataset.tab === currentTab));
  document.querySelectorAll("[id^='tab-']").forEach(p => { p.hidden = p.id !== "tab-" + currentTab; });
  loadTab(currentTab);
});

function tradeRowHTML(row, mode){
  const iAmSender = row.from_profile === session.user.id;
  const otherId = iAmSender ? row.to_profile : row.from_profile;
  const otherName = profileNameCache[otherId] || "…";
  const mine = iAmSender ? row.offered : row.requested;
  const theirs = iAmSender ? row.requested : row.offered;
  let actions = "";
  if (mode === "received" && row.status === "pending"){
    actions = '<div class="tradeactions"><button class="btn sm primary" type="button" data-accept="' + row.id + '">Accepter</button>' +
      '<button class="btn sm" type="button" data-decline="' + row.id + '">Refuser</button></div>';
  } else if (mode === "sent" && row.status === "pending"){
    actions = '<div class="tradeactions"><button class="btn sm" type="button" data-cancel="' + row.id + '">Annuler</button></div>';
  }
  return '<div class="traderow">' +
    '<div class="tradehead"><b>' + esc(otherName) + '</b><span class="tstatus ' + row.status + '">' + esc(statusLabel(row.status)) + '</span></div>' +
    '<div class="tradecols">' +
      '<div class="tradecol"><span class="tlabel">Tu proposes</span><div class="tmini">' + miniHTML(mine) + '</div></div>' +
      '<div class="tradearrow">⇄</div>' +
      '<div class="tradecol"><span class="tlabel">Tu demandes</span><div class="tmini">' + miniHTML(theirs) + '</div></div>' +
    '</div>' + actions + '</div>';
}
function statusLabel(s){
  return { pending: "En attente", accepted: "Acceptée", declined: "Refusée", cancelled: "Annulée" }[s] || s;
}

async function loadTab(tab){
  const listId = tab + "List", statusId = tab + "Status";
  document.getElementById(statusId).textContent = "Chargement…";

  let query = supabaseClient.from("trade_offers").select("*");
  if (tab === "received") query = query.eq("to_profile", session.user.id).eq("status", "pending");
  else if (tab === "sent") query = query.eq("from_profile", session.user.id).eq("status", "pending");
  else query = query.or("from_profile.eq." + session.user.id + ",to_profile.eq." + session.user.id).neq("status", "pending");
  const { data, error } = await query.order("created_at", { ascending: false });
  if (error){ document.getElementById(statusId).textContent = "Erreur : " + error.message; return; }

  const rows = data || [];
  document.getElementById(statusId).textContent = rows.length ? "" : "Rien pour l'instant.";

  const otherIds = rows.map(r => tab === "received" ? r.from_profile : (tab === "sent" ? r.to_profile : (r.from_profile === session.user.id ? r.to_profile : r.from_profile)));
  await resolveProfileNames(otherIds);
  const allCardIds = rows.flatMap(r => [...(r.offered || []), ...(r.requested || [])].map(x => x.card_id));
  await resolveCards(allCardIds);

  document.getElementById(listId).innerHTML = rows.map(r => tradeRowHTML(r, tab)).join("");
}

document.getElementById("receivedList").addEventListener("click", async (e) => {
  const accept = e.target.closest("[data-accept]");
  const decline = e.target.closest("[data-decline]");
  if (accept){
    const { error } = await supabaseClient.rpc("respond_trade", { p_trade_id: accept.dataset.accept, p_accept: true });
    if (error){ toast(error.message); return; }
    toast("Échange accepté.");
    await refreshHud(); await loadTab("received");
  } else if (decline){
    const { error } = await supabaseClient.rpc("respond_trade", { p_trade_id: decline.dataset.decline, p_accept: false });
    if (error){ toast(error.message); return; }
    toast("Échange refusé.");
    await loadTab("received");
  }
});
document.getElementById("sentList").addEventListener("click", async (e) => {
  const cancel = e.target.closest("[data-cancel]");
  if (!cancel) return;
  const { error } = await supabaseClient.rpc("cancel_trade", { p_trade_id: cancel.dataset.cancel });
  if (error){ toast(error.message); return; }
  toast("Proposition annulée.");
  await loadTab("sent");
});

(async function(){
  if (!(await initPage())) return;
  await loadMyCollection();
  await loadTab("received");

  // Lien direct depuis la fiche d'un ami (trades.html?to=pseudo) : préremplit le pseudo et lance
  // la même recherche que le bouton, plutôt que de dupliquer la logique de loadTargetBtn.
  const toParam = new URLSearchParams(window.location.search).get("to");
  if (toParam){
    document.getElementById("targetUsername").value = toParam;
    document.getElementById("loadTargetBtn").click();
  }
})();
