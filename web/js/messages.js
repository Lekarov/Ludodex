/* Messagerie privée — private_messages/blocks/message_reports (voir 007_messages_and_moderation.sql).
   Pas de RPC ici : lecture/écriture directes soumises aux policies RLS (voir ce fichier), la
   notification à la réception est gérée par un trigger côté base (031_notify_messages.sql). */

let myBlocks = new Set(); // profils que JE bloque
let convos = [];          // [{ profileId, lastMessage, lastAt, unread }]
let activeWith = null;
let activeLog = [];
let convoFilter = "";

function initials1(name){ return (name || "?")[0].toUpperCase(); }

// Avatar réel (carte de collection choisie comme pp, voir account.js/054_profile_avatar_showcase.sql)
// pour savoir qui parle d'un coup d'œil — repli sur les initiales si le joueur n'en a pas choisi.
const avatarCache = {}; // profileId -> image_url | null
async function resolveAvatars(ids){
  const missing = [...new Set(ids)].filter(id => id && !(id in avatarCache));
  if (!missing.length) return;
  const { data } = await supabaseClient.from("profiles").select("id, avatar_card_id").in("id", missing);
  const cardIds = [...new Set((data || []).map(p => p.avatar_card_id).filter(Boolean))];
  const imgByCard = {};
  if (cardIds.length){
    const { data: cards } = await supabaseClient.from("all_cards_catalogue").select("card_id, image_url").in("card_id", cardIds);
    (cards || []).forEach(c => { imgByCard[c.card_id] = c.image_url; });
  }
  (data || []).forEach(p => { avatarCache[p.id] = p.avatar_card_id ? (imgByCard[p.avatar_card_id] || null) : null; });
  missing.forEach(id => { if (!(id in avatarCache)) avatarCache[id] = null; });
}
function avatarHTML(profileId, name, cls){
  const url = avatarCache[profileId];
  return '<span class="' + cls + '">' + (url ? '<img src="' + esc(url) + '" alt="">' : esc(initials1(name))) + '</span>';
}

async function loadBlocks(){
  const { data } = await supabaseClient.from("blocks").select("blocked_id").eq("blocker_id", session.user.id);
  myBlocks = new Set((data || []).map(r => r.blocked_id));
}

// Amis (public.friends, 056_friends_and_message_purge.sql) déjà acceptés : affichés d'office dans
// la liste, même sans historique, pour démarrer une discussion sans étape "ajouter" séparée.
async function loadFriendIds(){
  const { data } = await supabaseClient
    .from("friends").select("requester_id, addressee_id")
    .or("requester_id.eq." + session.user.id + ",addressee_id.eq." + session.user.id)
    .eq("status", "accepted");
  return (data || []).map(r => r.requester_id === session.user.id ? r.addressee_id : r.requester_id);
}

async function loadConvos(){
  const { data, error } = await supabaseClient
    .from("private_messages")
    .select("sender_id, recipient_id, content, created_at, read_at")
    .or("sender_id.eq." + session.user.id + ",recipient_id.eq." + session.user.id)
    .order("created_at", { ascending: false });
  if (error){ console.error(error); return; }

  const byPartner = new Map();
  (data || []).forEach(m => {
    const partner = m.sender_id === session.user.id ? m.recipient_id : m.sender_id;
    if (!byPartner.has(partner)){
      byPartner.set(partner, { profileId: partner, lastMessage: m.content, lastAt: m.created_at, unread: 0 });
    }
    if (m.recipient_id === session.user.id && !m.read_at) byPartner.get(partner).unread++;
  });

  const friendIds = await loadFriendIds();
  friendIds.forEach(id => {
    if (!byPartner.has(id)) byPartner.set(id, { profileId: id, lastMessage: "", lastAt: null, unread: 0 });
  });

  convos = [...byPartner.values()];
  await Promise.all([resolveProfileNames(convos.map(c => c.profileId)), resolveAvatars(convos.map(c => c.profileId))]);
  convos.sort((a, b) => {
    if (a.lastAt && b.lastAt) return new Date(b.lastAt) - new Date(a.lastAt);
    if (a.lastAt || b.lastAt) return a.lastAt ? -1 : 1;
    return (profileNameCache[a.profileId] || "").localeCompare(profileNameCache[b.profileId] || "");
  });
  renderConvos();
}

function renderConvos(){
  const list = document.getElementById("convoList");
  const filtered = convoFilter
    ? convos.filter(c => (profileNameCache[c.profileId] || "").toLowerCase().includes(convoFilter))
    : convos;
  list.innerHTML = filtered.length ? filtered.map(c => {
    const name = profileNameCache[c.profileId] || "…";
    return '<li class="convoitem' + (activeWith === c.profileId ? " active" : "") + '" data-id="' + c.profileId + '">' +
      avatarHTML(c.profileId, name, "cavatar") +
      '<div class="cbody"><div class="cname">' + esc(name) + '</div><div class="clast">' + esc(c.lastMessage || "Aucun message pour l'instant") + '</div></div>' +
      (c.unread ? '<span class="cunread">' + c.unread + '</span>' : '') +
      '</li>';
  }).join("") : '<li class="nempty" style="border:0;padding:1rem">Ajoute des amis pour commencer à discuter.</li>';
}

document.getElementById("convoSearch").addEventListener("input", (e) => {
  convoFilter = e.target.value.trim().toLowerCase();
  renderConvos();
});

document.getElementById("convoList").addEventListener("click", (e) => {
  const li = e.target.closest("[data-id]");
  if (!li) return;
  openConversation(li.dataset.id);
});

async function openConversation(profileId){
  activeWith = profileId;
  renderConvos();
  document.getElementById("msgEmpty").hidden = true;
  document.getElementById("msgActive").hidden = false;

  await Promise.all([
    resolveProfileNames([profileId, session.user.id]),
    resolveAvatars([profileId, session.user.id]),
  ]);
  document.getElementById("msgWithName").textContent = profileNameCache[profileId] || "…";
  document.getElementById("blockBtn").textContent = myBlocks.has(profileId) ? "Débloquer" : "Bloquer";

  const { data, error } = await supabaseClient
    .from("private_messages")
    .select("id, sender_id, recipient_id, content, created_at, read_at")
    .or("and(sender_id.eq." + session.user.id + ",recipient_id.eq." + profileId + "),and(sender_id.eq." + profileId + ",recipient_id.eq." + session.user.id + ")")
    .order("created_at", { ascending: true });
  if (error){ toast(error.message); return; }
  activeLog = data || [];
  renderLog();

  const unreadIds = activeLog.filter(m => m.recipient_id === session.user.id && !m.read_at).map(m => m.id);
  if (unreadIds.length){
    await supabaseClient.from("private_messages").update({ read_at: new Date().toISOString() }).in("id", unreadIds);
    await loadConvos();
  }
}

function renderLog(){
  const log = document.getElementById("msgLog");
  log.innerHTML = activeLog.map(m => {
    const mine = m.sender_id === session.user.id;
    const name = profileNameCache[m.sender_id] || "…";
    return '<div class="msgrow ' + (mine ? "mine" : "theirs") + '">' +
      avatarHTML(m.sender_id, name, "mbubbleavatar") +
      '<div class="msgbubble ' + (mine ? "mine" : "theirs") + '">' + esc(m.content) +
        '<time>' + new Date(m.created_at).toLocaleString("fr-FR") + '</time>' +
      '</div></div>';
  }).join("");
  log.scrollTop = log.scrollHeight;
}

document.getElementById("msgCompose").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!activeWith) return;
  const input = document.getElementById("msgInput");
  const content = input.value.trim();
  if (!content) return;
  const { error } = await supabaseClient.from("private_messages").insert({
    sender_id: session.user.id, recipient_id: activeWith, content,
  });
  if (error){ toast(error.message); return; }
  input.value = "";
  await openConversation(activeWith);
});

document.getElementById("blockBtn").addEventListener("click", async () => {
  if (!activeWith) return;
  if (myBlocks.has(activeWith)){
    const { error } = await supabaseClient.from("blocks").delete()
      .eq("blocker_id", session.user.id).eq("blocked_id", activeWith);
    if (error){ toast(error.message); return; }
    myBlocks.delete(activeWith);
    toast("Débloqué.");
  } else {
    if (!confirm("Bloquer ce joueur ? Il ne pourra plus t'envoyer de message.")) return;
    const { error } = await supabaseClient.from("blocks").insert({ blocker_id: session.user.id, blocked_id: activeWith });
    if (error){ toast(error.message); return; }
    myBlocks.add(activeWith);
    toast("Joueur bloqué.");
  }
  document.getElementById("blockBtn").textContent = myBlocks.has(activeWith) ? "Débloquer" : "Bloquer";
});

document.getElementById("reportBtn").addEventListener("click", () => {
  if (!activeWith || !activeLog.length){ toast("Aucun message à signaler."); return; }
  document.getElementById("reportWithName").textContent = profileNameCache[activeWith] || "ce joueur";
  document.getElementById("reportReason").selectedIndex = 0;
  document.getElementById("reportComment").value = "";
  document.getElementById("reportMsg").className = "msg";
  document.getElementById("reportDlg").showModal();
});

document.getElementById("reportDlgClose").addEventListener("click", () => document.getElementById("reportDlg").close());
document.getElementById("reportCancel").addEventListener("click", () => document.getElementById("reportDlg").close());

document.getElementById("reportSubmit").addEventListener("click", async () => {
  const lastFromThem = [...activeLog].reverse().find(m => m.sender_id === activeWith);
  if (!lastFromThem){ showMsg("reportMsg", "Aucun message de ce joueur à signaler.", "error"); return; }

  const reasonLabel = document.getElementById("reportReason").value;
  const comment = document.getElementById("reportComment").value.trim();
  const reason = comment ? reasonLabel + " — " + comment : reasonLabel;

  const { error } = await supabaseClient.from("message_reports").insert({
    message_id: lastFromThem.id, reporter_id: session.user.id, reason,
  });
  if (error){ showMsg("reportMsg", error.message, "error"); return; }
  document.getElementById("reportDlg").close();
  toast("Signalement envoyé.");
});

(async function(){
  if (!(await initPage())) return;
  await loadBlocks();
  await loadConvos();

  const withParam = new URLSearchParams(window.location.search).get("with");
  if (withParam) await openConversation(withParam);
})();
