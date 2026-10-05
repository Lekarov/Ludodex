/* Amis — vraie liste connectée à Supabase (public.friends, 056_friends_and_message_purge.sql).
   Remplace l'ancienne démo 100% locale (fausse liste d'amis IA, faux chat) : Défier/Échanger/
   Discuter renvoient vers les vraies pages (duels.html/trades.html/messages.html), "Voir" ouvre
   la vitrine publique du joueur (profile_showcase, déjà lisible par tout le monde). */

let myFriends = [];        // amitiés acceptées : [{ rowId, otherId }]
let incomingRequests = []; // demandes reçues en attente : [{ rowId, otherId }]
let outgoingRequests = []; // demandes envoyées, pas encore acceptées : [{ rowId, otherId }]
const usernameCache = {};

const FRIEND_COLORS = ["#e0577a", "#4fa3e3", "#e0a83a", "#59c17e", "#9b6fe0", "#e0673a", "#3ac7c2", "#c25ad1"];
function avatarColor(id){
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return FRIEND_COLORS[h % FRIEND_COLORS.length];
}

async function resolveUsernames(ids){
  const missing = [...new Set(ids)].filter(id => id && !(id in usernameCache));
  if (!missing.length) return;
  const { data } = await supabaseClient.from("profiles").select("id, username").in("id", missing);
  (data || []).forEach(p => { usernameCache[p.id] = p.username; });
  missing.forEach(id => { if (!(id in usernameCache)) usernameCache[id] = "?"; });
}

function showDlg(){ const d = document.getElementById("dlg"); if (!d.open) d.showModal(); }
function closeDlg(){ document.getElementById("dlg").close(); }
document.getElementById("dlgClose").addEventListener("click", closeDlg);

async function loadFriends(){
  const me = session.user.id;
  const { data, error } = await supabaseClient
    .from("friends")
    .select("id, requester_id, addressee_id, status")
    .or("requester_id.eq." + me + ",addressee_id.eq." + me);
  if (error){ document.getElementById("friendsStatus").textContent = "Erreur : " + error.message; return; }

  const accepted = [], incoming = [], outgoing = [];
  (data || []).forEach(r => {
    const otherId = r.requester_id === me ? r.addressee_id : r.requester_id;
    if (r.status === "accepted") accepted.push({ rowId: r.id, otherId });
    else if (r.status === "pending" && r.addressee_id === me) incoming.push({ rowId: r.id, otherId });
    else if (r.status === "pending" && r.requester_id === me) outgoing.push({ rowId: r.id, otherId });
  });

  await resolveUsernames([...accepted.map(a => a.otherId), ...incoming.map(a => a.otherId), ...outgoing.map(a => a.otherId)]);
  myFriends = accepted;
  incomingRequests = incoming;
  outgoingRequests = outgoing;
  renderAmis();
}

function friendRowHTML(f){
  const name = usernameCache[f.otherId] || "…";
  return '<li class="mrow"><span class="pavatar" style="background:' + avatarColor(f.otherId) + '">' + esc(initials(name)) + '</span>' +
    '<div><button class="mt" type="button" data-act="viewFriend" data-id="' + f.otherId + '">' + esc(name) + '</button></div>' +
    '<div class="mside mactions">' +
      '<a class="micon" href="duels.html" title="Lancer un duel" aria-label="Lancer un duel">' + MENU_ICONS["duels.html"] + '</a>' +
      '<a class="micon" href="trades.html?to=' + encodeURIComponent(name) + '" title="Échanger" aria-label="Échanger avec ' + esc(name) + '">' + MENU_ICONS["trades.html"] + '</a>' +
      '<button class="micon" type="button" data-act="viewFriend" data-id="' + f.otherId + '" title="Voir le profil" aria-label="Voir le profil de ' + esc(name) + '">' + ICON_EYE + '</button>' +
      '<a class="micon" href="messages.html?with=' + f.otherId + '" title="Discuter" aria-label="Discuter avec ' + esc(name) + '">' + MENU_ICONS["messages.html"] + '</a>' +
    '</div></li>';
}

function requestRowHTML(r){
  const name = usernameCache[r.otherId] || "…";
  return '<li class="mrow"><span class="pavatar" style="background:' + avatarColor(r.otherId) + '">' + esc(initials(name)) + '</span>' +
    '<div><div class="mt" style="cursor:default">' + esc(name) + '</div><div class="ms">Demande d\'ami</div></div>' +
    '<div class="mside mactions">' +
      '<button class="btn sm" type="button" data-act="acceptFriend" data-row="' + r.rowId + '">Accepter</button>' +
      '<button class="micon" type="button" data-act="declineFriend" data-row="' + r.rowId + '" title="Refuser" aria-label="Refuser">×</button>' +
    '</div></li>';
}

function outgoingRowHTML(r){
  const name = usernameCache[r.otherId] || "…";
  return '<li class="mrow"><span class="pavatar" style="background:' + avatarColor(r.otherId) + '">' + esc(initials(name)) + '</span>' +
    '<div><div class="mt" style="cursor:default">' + esc(name) + '</div><div class="ms">Demande envoyée — en attente</div></div>' +
    '<div class="mside mactions">' +
      '<button class="btn sm" type="button" data-act="cancelFriend" data-row="' + r.rowId + '">Annuler</button>' +
    '</div></li>';
}

function renderAmis(){
  document.getElementById("requestsPanel").hidden = !incomingRequests.length;
  document.getElementById("friendRequests").innerHTML = incomingRequests.map(requestRowHTML).join("");

  document.getElementById("outgoingPanel").hidden = !outgoingRequests.length;
  document.getElementById("outgoingRequests").innerHTML = outgoingRequests.map(outgoingRowHTML).join("");

  document.getElementById("friendsStatus").textContent = myFriends.length
    ? myFriends.length + " ami" + (myFriends.length > 1 ? "s" : "")
    : "Pas encore d'ami — ajoute un pseudo ci-dessus.";
  document.getElementById("friendList").innerHTML = myFriends.map(friendRowHTML).join("");
}

async function addFriendGo(){
  const raw = document.getElementById("newFriendName").value.trim();
  if (!raw){ showMsg("addFriendMsg", "Indique un pseudo.", "error"); return; }

  const { data, error } = await supabaseClient
    .from("profiles").select("id, username").ilike("username", raw).limit(1);
  if (error){ showMsg("addFriendMsg", error.message, "error"); return; }
  if (!data || !data.length){ showMsg("addFriendMsg", "Aucun joueur avec ce pseudo.", "error"); return; }
  const target = data[0];
  if (target.id === session.user.id){ showMsg("addFriendMsg", "C'est toi-même.", "error"); return; }

  // Si l'autre t'a déjà envoyé une demande, on l'accepte directement plutôt que de créer une
  // seconde ligne en sens inverse (la contrainte d'unicité porte sur la paire ORDONNÉE
  // requester/addressee, pas sur la paire de joueurs elle-même).
  const { data: reverse } = await supabaseClient.from("friends").select("id, status")
    .eq("requester_id", target.id).eq("addressee_id", session.user.id).limit(1);
  if (reverse && reverse.length){
    if (reverse[0].status === "pending"){
      const { error: upErr } = await supabaseClient.from("friends").update({ status: "accepted" }).eq("id", reverse[0].id);
      if (upErr){ showMsg("addFriendMsg", upErr.message, "error"); return; }
      showMsg("addFriendMsg", target.username + " est maintenant ton ami.", "ok");
    } else {
      showMsg("addFriendMsg", "Vous êtes déjà amis.", "error");
    }
    document.getElementById("newFriendName").value = "";
    await loadFriends();
    return;
  }

  const { error: insErr } = await supabaseClient.from("friends")
    .insert({ requester_id: session.user.id, addressee_id: target.id });
  if (insErr){
    showMsg("addFriendMsg", insErr.code === "23505" ? "Demande déjà envoyée." : insErr.message, "error");
    return;
  }
  document.getElementById("newFriendName").value = "";
  showMsg("addFriendMsg", "Demande envoyée à " + target.username + ".", "ok");
}

async function acceptFriend(rowId){
  const { error } = await supabaseClient.from("friends").update({ status: "accepted" }).eq("id", rowId);
  if (error){ toast(error.message); return; }
  toast("Ami ajouté.");
  await loadFriends();
}

async function declineFriend(rowId){
  const { error } = await supabaseClient.from("friends").delete().eq("id", rowId);
  if (error){ toast(error.message); return; }
  await loadFriends();
}

async function cancelFriend(rowId){
  const { error } = await supabaseClient.from("friends").delete().eq("id", rowId);
  if (error){ toast(error.message); return; }
  toast("Demande annulée.");
  await loadFriends();
}

async function openViewFriend(otherId){
  const { data: profRows } = await supabaseClient
    .from("profiles").select("username, role, vip, created_at").eq("id", otherId).single();
  const name = (profRows && profRows.username) || usernameCache[otherId] || "…";

  const { data } = await supabaseClient
    .from("profile_showcase").select("slot, card_id, shiny").eq("profile_id", otherId);
  const rows = (data || []).slice().sort((a, b) => a.slot - b.slot);

  const cardIds = rows.map(r => r.card_id);
  let cardsById = {};
  if (cardIds.length){
    const { data: cards } = await supabaseClient
      .from("all_cards_catalogue").select("card_id, " + CARD_FIELDS).in("card_id", cardIds);
    (cards || []).forEach(c => { cardsById[c.card_id] = c; });
  }

  const badges = profRows
    ? roleBadgeHTML(profRows.role) + (profRows.vip && profRows.role !== "vip" ? roleBadgeHTML("vip") : "")
    : "";
  const joined = profRows && profRows.created_at
    ? '<p class="dsub" style="margin:.2rem 0 0">Membre depuis ' +
        new Date(profRows.created_at).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }) + '</p>'
    : "";

  document.getElementById("dlgBody").innerHTML =
    '<div class="form profileview">' +
      '<div class="pfhead"><span class="pavatar big" style="background:' + avatarColor(otherId) + '">' + esc(initials(name)) + '</span>' +
        '<div><h3 class="dtitle" style="margin:0 0 .3rem">' + esc(name) + badges + '</h3>' + joined + '</div>' +
      '</div>' +
      '<h4>Vitrine</h4>' +
      '<div class="grid">' + (rows.length
        ? rows.map(r => {
            const g = cardsById[r.card_id];
            return g ? '<div class="cw slot">' + cardHTML(g, { shiny: r.shiny }) + '</div>' : "";
          }).join("")
        : '<p class="empty">Rien à montrer pour l\'instant.</p>') + '</div>' +
      '<div class="actions">' +
        '<a class="btn" href="messages.html?with=' + otherId + '">' + MENU_ICONS["messages.html"] + ' Discuter</a>' +
        '<a class="btn" href="trades.html?to=' + encodeURIComponent(name) + '">' + MENU_ICONS["trades.html"] + ' Échanger</a>' +
      '</div>' +
    '</div>';
  showDlg();
}

document.getElementById("addFriendBtn").addEventListener("click", addFriendGo);
document.getElementById("newFriendName").addEventListener("keydown", (e) => {
  if (e.key === "Enter") addFriendGo();
});

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act;
  if (act === "viewFriend") openViewFriend(b.dataset.id);
  else if (act === "acceptFriend") acceptFriend(b.dataset.row);
  else if (act === "declineFriend") declineFriend(b.dataset.row);
  else if (act === "cancelFriend") cancelFriend(b.dataset.row);
});

(async function(){
  if (!(await initPage())) return;
  await loadFriends();
})();
