/* Cloche de notifications, partagée par toutes les pages connectées (voir 029/030/031_notify_*.sql
   pour ce qui les déclenche : succès débloqué, mise dépassée, enchère gagnée, carte vendue,
   message reçu). Indépendant de shared.js (récupère sa propre session) pour fonctionner aussi sur
   account.html, qui gère la sienne séparément. */

const NOTIF_POLL_MS = 20000;
let notifItems = [];

function notifIcon(type){
  return {
    achievement: "🏆", outbid: "⚠️", auction_won: "🎉", listing_sold: "💰", message: "✉️",
    trade_offer: "🔁", trade_accepted: "🤝", trade_declined: "🔁", duel_result: "⚔️",
    wishlist_available: "⭐", gold_unique: "✨", new_report: "🚩", support_resolved: "💬",
  }[type] || "🔔";
}
function notifLinkHref(n){
  if (n.link_type === "listing") return "listing.html?id=" + encodeURIComponent(n.link_id);
  if (n.link_type === "achievement") return "achievements.html";
  if (n.link_type === "message") return "messages.html?with=" + encodeURIComponent(n.link_id);
  if (n.link_type === "trade") return "trades.html?id=" + encodeURIComponent(n.link_id);
  if (n.link_type === "duel") return "duels.html?id=" + encodeURIComponent(n.link_id);
  if (n.link_type === "report") return "admin.html?report=" + encodeURIComponent(n.link_id);
  return null;
}
function notifTimeAgo(iso){
  const s = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return "à l'instant";
  const m = Math.floor(s / 60); if (m < 60) return "il y a " + m + " min";
  const h = Math.floor(m / 60); if (h < 24) return "il y a " + h + " h";
  return "il y a " + Math.floor(h / 24) + " j";
}

function renderNotifPanel(){
  const list = document.getElementById("notifList");
  const bubble = document.getElementById("notifBubble");
  if (!list) return;
  const unread = notifItems.filter(n => !n.read).length;
  if (bubble){
    bubble.textContent = unread > 9 ? "9+" : String(unread);
    bubble.hidden = unread === 0;
  }
  list.innerHTML = notifItems.length ? notifItems.map(n =>
    '<li class="' + (n.read ? "" : "unread") + '" data-id="' + n.id + '">' +
    '<span class="ni">' + notifIcon(n.type) + '</span>' +
    '<div><div>' + esc(n.title) + (n.body ? " — " + esc(n.body) : "") + '</div><small>' + notifTimeAgo(n.created_at) + '</small></div>' +
    '</li>'
  ).join("") : '<li class="nempty" style="border-top:0">Rien pour l\'instant.</li>';
}

async function loadNotifications(){
  const { data, error } = await supabaseClient
    .from("notifications")
    .select("id, type, title, body, link_type, link_id, read, created_at")
    .order("created_at", { ascending: false })
    .limit(30);
  if (error){ console.error(error); return; }
  notifItems = data || [];
  renderNotifPanel();
}

async function markNotifRead(id){
  const item = notifItems.find(n => n.id === id);
  if (item && !item.read){ item.read = true; renderNotifPanel(); }
  await supabaseClient.from("notifications").update({ read: true }).eq("id", id);
}

function setupNotifBell(){
  const bell = document.getElementById("notifBell");
  const panel = document.getElementById("notifPanel");
  if (!bell || !panel) return;

  bell.addEventListener("click", (e) => {
    e.stopPropagation();
    const willOpen = panel.hidden;
    panel.hidden = !willOpen;
    if (willOpen) loadNotifications();
  });
  document.addEventListener("click", (e) => {
    if (!panel.hidden && !panel.contains(e.target) && e.target !== bell) panel.hidden = true;
  });
  panel.addEventListener("click", (e) => {
    const li = e.target.closest("[data-id]");
    if (!li) return;
    const n = notifItems.find(x => x.id === li.dataset.id);
    if (!n) return;
    markNotifRead(n.id);
    const href = notifLinkHref(n);
    if (href) window.location.href = href;
  });
}

(async function initNotifications(){
  const { data: { session: s } } = await supabaseClient.auth.getSession();
  if (!s) return;
  setupNotifBell();
  await loadNotifications();
  setInterval(loadNotifications, NOTIF_POLL_MS);
})();
