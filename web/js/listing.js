/* Détail d'une annonce du marché (vente ou enchère) : carte, statut, et pour une enchère
   l'historique COMPLET des mises (jamais purgé — market_bids n'est jamais vidé côté serveur). */

function statRow(label, valueHTML){
  return '<div class="statrow"><span>' + esc(label) + '</span><span>' + valueHTML + '</span></div>';
}
function coinsHTML(n){
  return fmt(n) + '<span class="coin" aria-hidden="true"></span>';
}
function partyName(type, profileId, botName){
  if (type === "bot") return botName || "Bot";
  return profileNameCache[profileId] || "…";
}

let listingId = null;
let countdownTimer = null;

async function loadListing(){
  const id = new URLSearchParams(window.location.search).get("id");
  if (!id){
    document.getElementById("listStatus").textContent = "Aucune annonce indiquée.";
    return;
  }
  listingId = id;
  if (countdownTimer){ clearInterval(countdownTimer); countdownTimer = null; }

  // Une enchère peut avoir expiré depuis l'affichage précédent (résolution paresseuse, comme
  // market.js) — sans ça, miser sur une enchère déjà terminée échouerait côté RPC sans explication.
  await supabaseClient
    .from("market_listings").select("id").eq("id", id).eq("status", "active").eq("listing_type", "auction")
    .lte("ends_at", new Date().toISOString())
    .then(({ data }) => (data && data.length ? supabaseClient.rpc("resolve_auction", { p_listing_id: id }) : null));

  const { data: row, error } = await supabaseClient
    .from("market_listings")
    .select("id, seller_type, seller_profile_id, bot_name, buyer_profile_id, listing_type, shiny, price, status, ends_at, created_at, card_id, card_catalogue(" + CARD_FIELDS + ")")
    .eq("id", id)
    .single();
  if (error || !row){
    document.getElementById("listStatus").textContent = "Cette annonce est introuvable.";
    return;
  }

  const g = row.card_catalogue;
  let bids = [];
  if (row.listing_type === "auction"){
    const { data: b } = await supabaseClient
      .from("market_bids")
      .select("id, bidder_type, bidder_profile_id, amount, created_at")
      .eq("listing_id", id)
      .order("created_at", { ascending: false });
    bids = b || [];
  }

  await resolveProfileNames([
    row.seller_profile_id, row.buyer_profile_id,
    ...bids.map(b => b.bidder_profile_id),
  ]);

  document.getElementById("listStatus").hidden = true;
  document.getElementById("listingBody").hidden = false;

  document.getElementById("listingCardWrap").innerHTML = g ? cardBlockHTML(g, row.shiny, {}) : "";
  document.getElementById("listTitle").textContent = g ? g.title : row.card_id;
  document.getElementById("listSeller").textContent = "Mis en vente par " + partyName(row.seller_type, row.seller_profile_id, row.bot_name);

  const topBid = bids.length ? bids.reduce((m, b) => Math.max(m, b.amount), 0) : null;
  const leader = bids.length ? bids.find(b => b.amount === topBid) : null;
  const isMine = row.seller_type === "player" && row.seller_profile_id === session.user.id;

  let stats = "";
  if (row.status === "active"){
    if (row.listing_type === "auction"){
      stats += statRow("Mise actuelle", coinsHTML(topBid || row.price));
      stats += statRow("Meneur", leader ? esc(partyName(leader.bidder_type, leader.bidder_profile_id)) : "Aucune mise");
      stats += statRow("Fin", '<span id="listEndsIn">' + esc(formatTimeLeft(row.ends_at)) + '</span>');
    } else {
      stats += statRow("Prix", coinsHTML(row.price));
    }
    stats += statRow("Statut", "En vente");
  } else if (row.status === "sold"){
    const paid = row.listing_type === "auction" ? (topBid || row.price) : row.price;
    stats += statRow("Achetée pour", coinsHTML(paid));
    if (row.listing_type === "auction"){
      stats += statRow("Meneur", esc(partyName("player", row.buyer_profile_id)));
    }
    stats += statRow("Statut", "Vendue");

    const note = document.getElementById("listNote");
    note.hidden = false;
    const verb = row.listing_type === "auction" ? "Remportée par " : "Achetée par ";
    note.innerHTML = "<p>" + verb + "<strong>" + esc(partyName("player", row.buyer_profile_id)) + "</strong> pour " + coinsHTML(paid) + ".</p>";
  } else {
    stats += statRow("Statut", "Annulée / non vendue");
  }
  document.getElementById("listStats").innerHTML = stats;

  if (row.listing_type === "auction" && bids.length){
    document.getElementById("listHistoryPanel").hidden = false;
    document.getElementById("histCount").textContent = bids.length;
    document.getElementById("bidList").innerHTML = bids.map(b =>
      '<li><span><span class="bidwho">' + esc(partyName(b.bidder_type, b.bidder_profile_id)) + '</span>' +
      '<span class="bidwhen">' + new Date(b.created_at).toLocaleString("fr-FR") + '</span></span>' +
      '<span class="bidamt">' + coinsHTML(b.amount) + '</span></li>'
    ).join("");
  }

  renderListingActions(row, isMine, topBid);

  // Compte à rebours mis à jour à la seconde (comme WikiMasters) ; se relance depuis le serveur
  // une fois à zéro pour constater la résolution de l'enchère plutôt que de rester bloqué à "Terminée".
  if (row.status === "active" && row.listing_type === "auction" && row.ends_at){
    countdownTimer = setInterval(() => {
      const el = document.getElementById("listEndsIn");
      if (!el){ clearInterval(countdownTimer); return; }
      const left = formatTimeLeft(row.ends_at);
      el.textContent = left;
      if (left === "Terminée"){ clearInterval(countdownTimer); loadListing(); }
    }, 1000);
  }
}

/* ===== Miser / acheter / annuler depuis la fiche (comme sur market.html, en plus de la grille) ===== */
function renderListingActions(row, isMine, topBid){
  const box = document.getElementById("listActions");
  if (row.status !== "active"){ box.hidden = true; box.innerHTML = ""; return; }
  box.hidden = false;

  if (isMine){
    const canCancel = row.listing_type === "sale" || !topBid;
    box.innerHTML = canCancel
      ? '<button class="btn" type="button" id="listCancelBtn">Annuler l\'annonce</button>'
      : '<p class="sub" style="margin:0">Des enchères ont déjà été placées, impossible d\'annuler.</p>';
    if (canCancel){
      document.getElementById("listCancelBtn").addEventListener("click", async () => {
        const rpc = row.listing_type === "auction" ? "cancel_auction_listing" : "cancel_sale_listing";
        const { error } = await supabaseClient.rpc(rpc, { p_listing_id: row.id });
        if (error){ toast(error.message); return; }
        toast("Annonce annulée.");
        await loadListing();
      });
    }
    return;
  }

  if (row.listing_type === "sale"){
    box.innerHTML = '<button class="btn primary" type="button" id="listBuyBtn">Acheter pour ' + coinsHTML(row.price) + '</button>';
    document.getElementById("listBuyBtn").addEventListener("click", async () => {
      if (!confirm("Confirmer l'achat de cette carte ?")) return;
      const { error } = await supabaseClient.rpc("buy_listing", { p_listing_id: row.id });
      if (error){ toast(error.message); return; }
      toast("Achat effectué.");
      await refreshHud();
      await loadListing();
    });
    return;
  }

  // Enchère d'un autre joueur : mise minimum = mise actuelle +7% (au moins +1), comme market.js.
  const minBid = topBid ? topBid + Math.max(1, Math.round(topBid * 0.07)) : row.price;
  box.innerHTML =
    '<div class="mlabel" style="margin-bottom:.35rem">Mise (minimum ' + fmt(minBid) + ')</div>' +
    '<div class="stepper">' +
      '<button type="button" id="listBidMinus" aria-label="Diminuer">−</button>' +
      '<input type="text" id="listBidAmount" inputmode="numeric" value="' + minBid + '">' +
      '<button type="button" id="listBidPlus" aria-label="Augmenter">+</button>' +
    '</div>' +
    '<button class="btn primary" type="button" id="listBidBtn" style="margin-top:.6rem">Miser</button>';

  const amountInput = document.getElementById("listBidAmount");
  document.getElementById("listBidMinus").addEventListener("click", () => {
    amountInput.value = Math.max(minBid, (parseInt(amountInput.value, 10) || minBid) - 5);
  });
  document.getElementById("listBidPlus").addEventListener("click", () => {
    amountInput.value = (parseInt(amountInput.value, 10) || minBid) + 5;
  });
  document.getElementById("listBidBtn").addEventListener("click", async () => {
    const amount = parseInt(amountInput.value, 10);
    if (!amount || amount < minBid){ toast("Indique une mise d'au moins " + fmt(minBid) + "."); return; }
    const { error } = await supabaseClient.rpc("place_bid", { p_listing_id: row.id, p_amount: amount });
    if (error){ toast(error.message); return; }
    toast("Mise enregistrée.");
    await loadListing();
  });
}

(async function(){
  if (!(await initPage())) return;
  await loadListing();
})();
