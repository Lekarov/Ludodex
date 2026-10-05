function showMsg(id, text, kind){
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = "msg show " + kind;
}

let currentSession = null;

// CARD_FIELDS n'est défini que par shared.js (non chargé ici, cette page gère sa propre session) :
// on prend les champs affichés par cardHTML + ceux utiles à la recherche dans le sélecteur de
// carte (avatar/vitrine).
const CARD_FIELDS = "title, platform_name, rarity, rarity_name, rarity_color, family_color, atk, def, image_url, genres";

async function loadAccount(){
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session){ window.location.href = "login.html"; return; }
  currentSession = session;

  document.getElementById("whoami").textContent = session.user.email || "Connecté via un fournisseur externe";

  const { data: profile, error } = await supabaseClient
    .from("profiles")
    .select("username, role, vip")
    .eq("id", session.user.id)
    .single();
  if (error){ showMsg("accountMsg", "Impossible de charger le profil : " + error.message, "error"); return; }

  document.getElementById("username").value = profile.username;
  document.getElementById("profileName").innerHTML = esc(profile.username) +
    roleBadgeHTML(profile.role) + (profile.vip && profile.role !== "vip" ? roleBadgeHTML("vip") : "");

  // Colonnes séparées (054_profile_avatar_showcase.sql) : si la migration n'est pas encore
  // appliquée, on n'empêche pas le reste du profil de s'afficher, l'avatar reste juste sur les
  // initiales en attendant.
  const { data: avatarRow } = await supabaseClient
    .from("profiles").select("avatar_card_id, avatar_shiny").eq("id", session.user.id).maybeSingle();
  await renderAvatar(avatarRow && avatarRow.avatar_card_id, avatarRow && avatarRow.avatar_shiny);

  const { data: state } = await supabaseClient
    .from("player_state")
    .select("coins")
    .eq("profile_id", session.user.id)
    .single();
  if (state) document.getElementById("coins").textContent = state.coins;
}

document.getElementById("logoutBtn").addEventListener("click", async () => {
  await supabaseClient.auth.signOut();
  window.location.href = "login.html";
});

document.getElementById("saveUsername").addEventListener("click", async () => {
  const { data: { session } } = await supabaseClient.auth.getSession();
  const username = document.getElementById("username").value.trim();
  if (username.length < 3){ showMsg("accountMsg", "Le pseudo doit faire au moins 3 caractères.", "error"); return; }
  const { error } = await supabaseClient.from("profiles").update({ username }).eq("id", session.user.id);
  if (error){ showMsg("accountMsg", error.message.includes("duplicate") ? "Ce pseudo est déjà pris." : error.message, "error"); return; }
  showMsg("accountMsg", "Pseudo mis à jour.", "ok");
  document.getElementById("profileName").textContent = username;
});

/* ===== Photo de profil : une carte de la collection sert d'avatar (pas d'upload libre — voir
   054_profile_avatar_showcase.sql). "Bien cadrée" = object-fit:cover + object-position réglé pour
   privilégier le tiers supérieur de la jaquette, où logo/personnage principal se trouvent le plus
   souvent, plutôt qu'un centrage brut qui coupe fréquemment le haut de l'image. ===== */
async function renderAvatar(cardId, shiny){
  const box = document.getElementById("avatarInitial");
  if (!cardId){
    const name = document.getElementById("username").value || "?";
    box.parentElement.classList.remove("has-img");
    box.textContent = name[0].toUpperCase();
    return;
  }
  const { data: g } = await supabaseClient
    .from("all_cards_catalogue").select("image_url").eq("card_id", cardId).maybeSingle();
  if (!g || !g.image_url){
    box.parentElement.classList.remove("has-img");
    box.textContent = "?";
    return;
  }
  box.parentElement.classList.add("has-img");
  box.innerHTML = '<img src="' + esc(g.image_url) + '" alt="">';
}

/* ===== Vitrine : 4 emplacements, chacun une carte de la collection (profile_showcase) ===== */
async function loadShowcase(){
  const { data: { session } } = await supabaseClient.auth.getSession();
  const { data } = await supabaseClient
    .from("profile_showcase")
    .select("slot, card_id, shiny")
    .eq("profile_id", session.user.id);
  const bySlot = {};
  (data || []).forEach(r => { bySlot[r.slot] = r; });

  const cardIds = (data || []).map(r => r.card_id);
  const cardsById = {};
  if (cardIds.length){
    const { data: cards } = await supabaseClient
      .from("all_cards_catalogue").select("card_id, " + CARD_FIELDS).in("card_id", cardIds);
    (cards || []).forEach(c => { cardsById[c.card_id] = c; });
  }

  document.getElementById("showcaseSlots").innerHTML = [1, 2, 3, 4].map(slot => {
    const row = bySlot[slot];
    const g = row && cardsById[row.card_id];
    if (row && g){
      return '<div class="showslot filled">' +
        '<div class="cw">' + cardHTML(g, { shiny: row.shiny }) + '</div>' +
        '<button type="button" class="showslot-x" data-remove-slot="' + slot + '" aria-label="Retirer cette carte de la vitrine">×</button>' +
      '</div>';
    }
    return '<button type="button" class="showslot empty" data-pick-slot="' + slot + '">' +
      '<span>+</span><span class="showslot-label">Ajouter</span></button>';
  }).join("");
}

document.getElementById("showcaseSlots").addEventListener("click", (e) => {
  const rm = e.target.closest("[data-remove-slot]");
  if (rm){ removeShowcaseSlot(+rm.dataset.removeSlot); return; }
  const pick = e.target.closest("[data-pick-slot]");
  if (pick) openCardPicker({ slot: +pick.dataset.pickSlot });
});

async function removeShowcaseSlot(slot){
  const { data: { session } } = await supabaseClient.auth.getSession();
  await supabaseClient.from("profile_showcase").delete().eq("profile_id", session.user.id).eq("slot", slot);
  await loadShowcase();
}

async function setShowcaseSlot(slot, cardId, shiny){
  const { data: { session } } = await supabaseClient.auth.getSession();
  const { error } = await supabaseClient.from("profile_showcase")
    .upsert({ profile_id: session.user.id, slot, card_id: cardId, shiny }, { onConflict: "profile_id,slot" });
  if (error){ toast(error.message); return; }
  await loadShowcase();
}

/* ===== Sélecteur de carte partagé (avatar + vitrine) : cartes de la collection possédée ===== */
let pickTarget = null; // "avatar" | { slot: N }
let myCollectionCache = null;

async function loadMyCollectionForPicker(){
  if (myCollectionCache) return myCollectionCache;
  const { data: { session } } = await supabaseClient.auth.getSession();
  const { data } = await supabaseClient
    .from("collection").select("card_id, shiny, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id);
  myCollectionCache = (data || []).filter(r => r.card_catalogue);
  return myCollectionCache;
}

function renderPickerGrid(rows, q){
  const filtered = q ? rows.filter(r => (r.card_catalogue.title || "").toLowerCase().includes(q)) : rows;
  document.getElementById("pickCardGrid").innerHTML = filtered.length
    ? filtered.map(r =>
        // .cw (pas juste le <button>) est indispensable : .card à l'intérieur est en
        // position:absolute/inset:0 et a besoin de ce conteneur position:relative + aspect-ratio
        // pour se dimensionner. Sans lui, la carte se positionne par rapport au <dialog> entier
        // (seul ancêtre positionné au sens du "top layer") au lieu de sa cellule de grille —
        // bug réel constaté par Doktor (carte géante unique dans le sélecteur de vitrine).
        '<button type="button" class="cw-click" data-pick="' + esc(r.card_id) + '" data-sh="' + (r.shiny ? 1 : 0) + '">' +
          '<div class="cw">' + cardHTML(r.card_catalogue, { shiny: r.shiny }) + '</div>' +
        '</button>'
      ).join("")
    : '<p class="empty">Aucune carte ne correspond — ouvre des boosters pour en obtenir !</p>';
}

async function openCardPicker(target){
  pickTarget = target;
  document.getElementById("pickCardTitle").textContent =
    target === "avatar" ? "Choisir une photo de profil" : "Choisir une carte pour la vitrine";
  document.getElementById("pickCardSearch").value = "";
  const rows = await loadMyCollectionForPicker();
  renderPickerGrid(rows, "");
  const dlg = document.getElementById("pickCardDlg");
  if (!dlg.open) dlg.showModal();
}

document.getElementById("avatarBtn").addEventListener("click", () => openCardPicker("avatar"));
document.getElementById("pickCardClose").addEventListener("click", () => document.getElementById("pickCardDlg").close());
document.getElementById("pickCardDlg").addEventListener("click", (e) => {
  if (e.target === document.getElementById("pickCardDlg")) document.getElementById("pickCardDlg").close();
});
document.getElementById("pickCardSearch").addEventListener("input", async (e) => {
  const rows = await loadMyCollectionForPicker();
  renderPickerGrid(rows, e.target.value.trim().toLowerCase());
});
document.getElementById("pickCardGrid").addEventListener("click", async (e) => {
  const b = e.target.closest("[data-pick]");
  if (!b) return;
  const cardId = b.dataset.pick, shiny = b.dataset.sh === "1";
  document.getElementById("pickCardDlg").close();
  if (pickTarget === "avatar"){
    const { data: { session } } = await supabaseClient.auth.getSession();
    const { error } = await supabaseClient.from("profiles")
      .update({ avatar_card_id: cardId, avatar_shiny: shiny }).eq("id", session.user.id);
    if (error){ toast(error.message); return; }
    await renderAvatar(cardId, shiny);
  } else {
    await setShowcaseSlot(pickTarget.slot, cardId, shiny);
  }
});

async function loadStats(){
  const { data, error } = await supabaseClient.rpc("get_achievement_progress");
  if (error){ document.getElementById("statsStatus").textContent = "Erreur : " + error.message; return; }

  document.getElementById("statsStatus").textContent = "";
  // Couleur par tuile : celles liées à une rareté reprennent EXACTEMENT les couleurs de
  // RARITY_ORDER (shared.js, pas chargé ici) en dur pour rester cohérentes avec le reste du site
  // (badges, bandeaux de carte...) ; les autres ont une couleur thématique propre.
  const tiles = [
    { v: data.boosters_opened_total, l: "Boosters ouverts", i: "🎴", c: "#3fb6c9" },
    { v: data.golds_opened_total, l: "Boosters dorés", i: "✨", c: "#f5c945" },
    { v: data.owned_distinct, l: "Cartes différentes", i: "📚", c: "#4f8ef7" },
    { v: data.shiny_drawn_total, l: "Brillantes tirées", i: "🌈", c: "#ff6ec7" },
    { v: data.pulls_rare, l: "Rares tirées", i: "🔷", c: "#2f74d0" },
    { v: data.pulls_epic, l: "Épiques tirées", i: "🔮", c: "#8a45d6" },
    { v: data.pulls_legendary, l: "Légendaires tirées", i: "👑", c: "#d99a14" },
    { v: data.pulls_mythic, l: "Mythiques tirées", i: "🌟", c: "#e0457b" },
    { v: data.platforms_completed, l: "Plateformes complètes", i: "🏁", c: "#3fbf72" },
    { v: data.sold_count, l: "Cartes vendues", i: "💱", c: "#ff9a4a" },
    { v: data.bought_count, l: "Cartes achetées", i: "🛒", c: "#4ac9c2" },
    { v: data.earned, l: "Pièces gagnées au marché", i: "🪙", c: "#f0c04a" },
  ];
  document.getElementById("statsTiles").innerHTML = tiles.map(t =>
    '<div class="tile" style="--tc:' + t.c + '"><span class="tile-ic" aria-hidden="true">' + t.i + '</span><b>' + fmt(t.v) + '</b><span class="tile-l">' + t.l + '</span></div>'
  ).join("");
}

async function loadGoldCards(){
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) return;
  const { data, error } = await supabaseClient
    .from("gold_claims")
    .select("card_id, claimed_at, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id)
    .order("claimed_at", { ascending: false });
  if (error || !data || !data.length) return; // panneau reste caché, rien à montrer
  document.getElementById("goldPanel").hidden = false;
  document.getElementById("goldList").innerHTML = data.map(row => {
    const g = row.card_catalogue || {};
    const d = new Date(row.claimed_at).toLocaleDateString("fr-FR", { day: "2-digit", month: "short", year: "numeric" });
    return '<div>' +
      '<div class="cw">' + cardHTML(g, { gold: true }) + '</div>' +
      '<p class="sub" style="text-align:center;margin:.4rem 0 0">Obtenue le ' + d + '</p></div>';
  }).join("");
}

loadAccount();
loadShowcase();
loadStats();
loadGoldCards();
