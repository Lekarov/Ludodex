// Hub modération/admin (admin.html). Indépendant du HUD pièces/boosters de shared.js (juste
// requireSession() est réutilisé) ; toute la logique d'élévation/rôle est propre à cette page.
//
// Toutes les actions passent par des champs inline stylés (jamais prompt()/confirm() natifs du
// navigateur) — retour Doktor 29/09/2026 : ces popups façon "fenêtre système" cassaient le visuel
// et donnaient l'impression que "le formulaire revient" de façon intempestive.

let hubExpiresAt = null;
let hubRole = null;
let clientIpPromise = null;

function getClientIp(){
  // Best-effort, déclaratif côté client (voir le commentaire dans 062_admin_hub_foundation.sql) :
  // juste pour le contexte de l'audit, jamais une preuve fiable côté serveur.
  if (!clientIpPromise){
    clientIpPromise = fetch("https://api.ipify.org?format=json")
      .then(r => r.json()).then(d => d.ip).catch(() => null);
  }
  return clientIpPromise;
}

function fmtDate(iso){
  if (!iso) return "—";
  return new Date(iso).toLocaleString("fr-FR", { dateStyle: "short", timeStyle: "short" });
}

// État vide générique du hub — réutilisé partout (signalements, annonces, joueurs, catalogue)
// plutôt qu'un <p> nu, pour que "rien à afficher" ait l'air prévu, pas oublié.
function admEmptyState(icon, title, sub){
  return '<div class="admempty"><div class="admempty-ico">' + icon + '</div><b>' + esc(title) + '</b>' +
    (sub ? '<p>' + esc(sub) + '</p>' : '') + '</div>';
}

function flash(msg, kind){
  const el = document.getElementById("hubFlash");
  if (!el) return;
  el.textContent = msg;
  el.className = "msg show " + (kind || "ok");
  clearTimeout(window._flashTimer);
  window._flashTimer = setTimeout(() => { el.className = "msg"; }, 4000);
}

// ===== Gate : session + rôle + élévation =====

async function checkStaffRole(){
  const { data, error } = await supabaseClient
    .from("profiles").select("role").eq("id", session.user.id).single();
  if (error || !data || !["moderator", "admin", "fondateur"].includes(data.role)){
    window.location.href = "boosters.html";
    return null;
  }
  hubRole = data.role;
  document.getElementById("hubRoleBadge").textContent = data.role;
  return data.role;
}

function showElevGate(msg){
  document.getElementById("elevGate").hidden = false;
  document.getElementById("hubBody").hidden = true;
  clearInterval(window._elevTimer);
  if (msg) showMsg("elevMsg", msg, "error");
}

function showHubBody(){
  document.getElementById("elevGate").hidden = true;
  document.getElementById("hubBody").hidden = false;
  startExpiryCountdown();
  loadDashboard();
  refreshImagesBadge();
  refreshSupportBadge();
}

function startExpiryCountdown(){
  const el = document.getElementById("elevExpiry");
  clearInterval(window._elevTimer);
  window._elevTimer = setInterval(() => {
    if (!hubExpiresAt) return;
    const leftMs = new Date(hubExpiresAt).getTime() - Date.now();
    if (leftMs <= 0){
      clearInterval(window._elevTimer);
      showElevGate("Session du hub expirée après 15 minutes, reconfirme ton mot de passe.");
      return;
    }
    const m = Math.floor(leftMs / 60000), s = Math.floor((leftMs % 60000) / 1000);
    el.textContent = "Session du hub active — expire dans " + m + ":" + String(s).padStart(2, "0");
  }, 1000);
}

async function submitElevation(){
  const pw = document.getElementById("elevPassword").value;
  const btn = document.getElementById("elevSubmit");
  if (!pw){ showMsg("elevMsg", "Mot de passe requis.", "error"); return; }
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc("grant_hub_elevation", { p_password: pw });
  btn.disabled = false;
  if (error){ showMsg("elevMsg", error.message, "error"); return; }
  hubExpiresAt = data;
  document.getElementById("elevPassword").value = "";
  showHubBody();
}

async function tryResumeElevation(){
  // Si l'élévation posée lors d'un chargement précédent de la page est encore valide côté
  // serveur, on évite de redemander le mot de passe à chaque rechargement dans la fenêtre de 15
  // minutes : get_admin_kpis() échoue proprement si _require_elevated() refuse (session expirée,
  // ou jamais ouverte) — c'est attendu, pas un bug, passé 15 minutes d'inactivité.
  const { data, error } = await supabaseClient.rpc("get_admin_kpis");
  if (error){ showElevGate(); return; }
  hubExpiresAt = new Date(Date.now() + 15 * 60000).toISOString(); // approximation, resynchronisée au prochain grant
  renderKpis(data);
  showHubBody();
}

// ===== Onglets =====

function setupTabs(){
  document.querySelectorAll(".admtab").forEach(a => {
    a.addEventListener("click", (e) => {
      e.preventDefault();
      const tab = a.dataset.tab;
      document.querySelectorAll(".admtab").forEach(x => x.removeAttribute("aria-current"));
      a.setAttribute("aria-current", "page");
      document.querySelectorAll(".admtabpanel").forEach(p => p.hidden = true);
      document.getElementById("tab-" + tab).hidden = false;
      if (tab === "players") loadPlayers();
      if (tab === "reports") loadReports();
      if (tab === "support") loadSupportTickets();
      if (tab === "announcements") loadAnnouncements();
      if (tab === "images") loadCatalogueGrid(true);
    });
  });
}

// ===== Dashboard =====

function renderKpis(k){
  const grid = document.getElementById("kpiGrid");
  const cards = [
    ["Joueurs", k.total_players], ["Pièces en circulation", k.total_coins],
    ["Boosters ouverts", k.total_boosters_opened], ["Signalements en attente", k.pending_reports],
    ["Comptes suspendus", k.suspended_players], ["Comptes muets", k.muted_players],
  ];
  grid.innerHTML = cards.map(([label, val]) =>
    '<div class="kpicard"><b>' + (val ?? 0) + '</b><span>' + esc(label) + '</span></div>'
  ).join("");
  const badge = document.getElementById("reportsBadge");
  if (k.pending_reports > 0){ badge.hidden = false; badge.textContent = k.pending_reports; }
  else badge.hidden = true;
}

async function loadDashboard(){
  const { data, error } = await supabaseClient.rpc("get_admin_kpis");
  if (error){ console.error(error); return; }
  renderKpis(data);
}

// ===== Joueurs =====

async function loadPlayers(){
  const search = document.getElementById("playerSearch").value.trim() || null;
  const sort = document.getElementById("playerSort").value;
  const { data, error } = await supabaseClient.rpc("list_players", { p_search: search, p_sort: sort, p_limit: 100, p_offset: 0 });
  const body = document.getElementById("playersBody");
  if (error){ body.innerHTML = '<tr><td colspan="7">' + esc(error.message) + '</td></tr>'; return; }
  body.innerHTML = (data || []).map(p => {
    const chips =
      (p.role !== "player" ? '<span class="statuschip vip">' + esc(p.role) + '</span>' : "") +
      (p.vip ? '<span class="statuschip vip">VIP</span>' : "") +
      (p.muted ? '<span class="statuschip muted">Muet</span>' : "") +
      (p.suspended ? '<span class="statuschip suspended">Suspendu</span>' : "");
    return '<tr>' +
      '<td>' + esc(p.username) + '</td>' +
      '<td>' + esc(p.role) + '</td>' +
      '<td>' + (p.coins ?? "—") + '</td>' +
      '<td>' + (p.card_count ?? 0) + '</td>' +
      '<td>' + (chips || "—") + '</td>' +
      '<td>' + fmtDate(p.created_at) + '</td>' +
      '<td><button class="linklike" data-id="' + p.profile_id + '" type="button">Voir</button></td>' +
      '</tr>';
  }).join("") || '<tr><td colspan="7">' + admEmptyState("👤", "Aucun joueur ne correspond", "Essaie un autre pseudo ou vide le champ de recherche.") + '</td></tr>';
}

async function exportPlayersCsv(){
  const { data, error } = await supabaseClient.rpc("list_players", { p_search: null, p_sort: "created_desc", p_limit: 200, p_offset: 0 });
  if (error){ alert(error.message); return; }
  const rows = [["pseudo", "role", "vip", "muet", "suspendu", "pieces", "boosters", "cartes", "cree_le"]];
  (data || []).forEach(p => rows.push([p.username, p.role, p.vip, p.muted, p.suspended, p.coins, p.boosters_available, p.card_count, p.created_at]));
  const csv = rows.map(r => r.map(v => '"' + String(v ?? "").replace(/"/g, '""') + '"').join(",")).join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "ludodex-joueurs-" + new Date().toISOString().slice(0, 10) + ".csv";
  a.click();
  URL.revokeObjectURL(a.href);
}

async function searchCardOwners(){
  const cardId = document.getElementById("cardOwnerSearch").value.trim();
  const box = document.getElementById("cardOwnersResult");
  if (!cardId){ box.hidden = true; return; }
  const { data, error } = await supabaseClient.rpc("search_card_owners", { p_card_id: cardId });
  box.hidden = false;
  if (error){ box.innerHTML = esc(error.message); return; }
  if (!data || !data.length){ box.innerHTML = "Personne ne possède cette carte."; return; }
  box.innerHTML = "<b>" + data.length + " détenteur(s) de " + esc(cardId) + " :</b><br>" +
    data.map(o => esc(o.username) + " — " + o.count + (o.shiny ? " ✨" : "")).join("<br>");
}

// ===== Fiche joueur (formulaires inline, jamais de prompt()/confirm() natifs) =====

async function openPlayerCard(id){
  const { data, error } = await supabaseClient.rpc("get_player_card", { p_target: id });
  if (error){ alert(error.message); return; }
  renderPlayerDlg(data);
  document.getElementById("playerDlg").showModal();
}

// Une "ligne d'action" = bouton principal + champ motif (+ champs optionnels) toujours visibles
// côte à côte, jamais de popup séparée. `fields` est du HTML additionnel avant le motif.
function actionRow(idPrefix, label, btnClass, extraFieldsHtml){
  return '<div class="pdlg-actionrow">' +
    (extraFieldsHtml || "") +
    '<input type="text" id="' + idPrefix + 'Reason" class="pdlg-reason" placeholder="Motif">' +
    '<button class="btn ' + (btnClass || "") + '" id="' + idPrefix + 'Btn" type="button">' + esc(label) + '</button>' +
    '</div>';
}

function renderPlayerDlg(d){
  const p = d.profile;
  const isAdmin = hubRole === "admin" || hubRole === "fondateur";
  const body = document.getElementById("playerDlgBody");

  const adminActions = isAdmin ? (
    '<div class="pdlg-section"><h3>Pièces</h3>' +
      actionRow("coin", "Ajuster", "", '<input type="number" id="coinDelta" placeholder="± pièces" class="pdlg-num">') +
    '</div>' +
    '<div class="pdlg-section"><h3>Compte</h3>' +
      actionRow("suspend", p.suspended ? "Lever la suspension" : "Suspendre", p.suspended ? "" : "danger") +
      actionRow("vip", p.vip ? "Retirer VIP" : "Accorder VIP", "") +
    '</div>' +
    '<div class="pdlg-section"><h3>Transférer une carte vers un autre joueur</h3>' +
      '<div class="pdlg-actionrow">' +
        '<input type="text" id="tCardId" placeholder="card_id" class="pdlg-txt">' +
        '<label class="pdlg-chk"><input type="checkbox" id="tShiny"> brillante</label>' +
        '<input type="number" id="tCount" placeholder="qté" value="1" min="1" class="pdlg-num">' +
        '<input type="text" id="tToUsername" placeholder="pseudo destinataire" class="pdlg-txt">' +
      '</div>' +
      actionRow("transfer", "Transférer") +
    '</div>' +
    '<div class="pdlg-section pdlg-danger"><h3>Zone sensible</h3>' +
      '<div class="pdlg-actionrow">' +
        '<input type="text" id="deleteConfirm" placeholder="Tape exactement le pseudo pour confirmer" class="pdlg-txt">' +
      '</div>' +
      actionRow("delete", "Supprimer définitivement le compte", "danger") +
    '</div>'
  ) : "";

  body.innerHTML =
    '<div class="pdlg-head"><h2>' + esc(p.username) + '</h2><span class="rolebadge" style="width:auto">' + esc(p.role) + '</span></div>' +
    '<div class="pdlg-grid">' +
      '<div><span>Pièces</span><b>' + d.coins + '</b></div>' +
      '<div><span>Boosters dispo</span><b>' + d.boosters_available + '</b></div>' +
      '<div><span>Cartes (distinctes/total)</span><b>' + d.card_count_distinct + ' / ' + d.card_count_total + '</b></div>' +
      '<div><span>Dernière connexion</span><b>' + fmtDate(d.last_login) + '</b></div>' +
      '<div><span>Collection publique</span><b>' + (p.collection_public ? "oui" : "non") + '</b></div>' +
      '<div><span>Inscrit le</span><b>' + fmtDate(p.created_at) + '</b></div>' +
    '</div>' +

    '<div class="pdlg-section"><h3>Modération</h3>' +
      actionRow("mute", p.muted ? "Démuter" : "Muter") +
      '<div class="pdlg-actionrow"><input type="text" id="renameNew" placeholder="Nouveau pseudo" class="pdlg-txt"></div>' +
      actionRow("rename", "Renommer") +
    '</div>' +
    adminActions +

    '<div class="pdlg-section"><h3>Notes internes (équipe)</h3>' +
      '<div class="pdlg-notes">' + (d.notes.length ? d.notes.map(n =>
        '<div class="pdlg-note">' + esc(n.note) + '<small>' + esc(n.author_username || "—") + ' · ' + fmtDate(n.created_at) + '</small></div>'
      ).join("") : '<div class="pdlg-note">Aucune note.</div>') + '</div>' +
      '<div class="pdlg-actionrow"><input type="text" id="newNote" placeholder="Ajouter une note…" class="pdlg-txt" style="flex:1"><button class="btn" id="noteBtn" type="button">Ajouter</button></div>' +
    '</div>' +

    '<div class="pdlg-section"><h3>Historique d\'audit (cette cible)</h3><div class="pdlg-hist">' +
      (d.audit_history.length ? d.audit_history.map(a =>
        '<div>' + fmtDate(a.created_at) + ' — <b>' + esc(a.action) + '</b> par ' + esc(a.actor_username || "—") +
        (a.reason ? " (" + esc(a.reason) + ")" : "") +
        (a.action === "adjust_coins" ? ' <button class="linklike" data-undo="' + a.id + '">annuler</button>' : "") +
        '</div>'
      ).join("") : "<div>Aucune action enregistrée.</div>") +
    '</div></div>' +

    '<div class="pdlg-section"><h3>Échanges récents</h3><div class="pdlg-hist">' +
      (d.recent_trades.length ? d.recent_trades.map(t =>
        '<div>' + fmtDate(t.created_at) + ' — ' + esc(t.status) + '</div>'
      ).join("") : "<div>Aucun.</div>") + '</div></div>' +

    '<div class="pdlg-section"><h3>Duels récents</h3><div class="pdlg-hist">' +
      (d.recent_duels.length ? d.recent_duels.map(du =>
        '<div>' + fmtDate(du.created_at) + ' — ' + (du.won ? "gagné" : "perdu") + ' (' + du.my_wins + '-' + du.their_wins + ') +' + du.reward + '</div>'
      ).join("") : "<div>Aucun.</div>") + '</div></div>';

  wirePlayerDlgActions(p.profile_id, p);
}

function wirePlayerDlgActions(id, p){
  const ip = getClientIp();
  const reload = () => openPlayerCard(id);
  const reasonOf = (prefix) => (document.getElementById(prefix + "Reason").value || "").trim();

  document.getElementById("muteBtn").addEventListener("click", async () => {
    const reason = reasonOf("mute");
    if (!reason){ flash("Motif requis.", "error"); return; }
    const { error } = await supabaseClient.rpc("set_player_muted", { p_target: id, p_muted: !p.muted, p_reason: reason, p_client_ip: await ip });
    if (error) flash(error.message, "error"); else { await loadPlayers(); reload(); }
  });

  document.getElementById("renameBtn").addEventListener("click", async () => {
    const newName = document.getElementById("renameNew").value.trim();
    const reason = reasonOf("rename");
    if (!newName || !reason){ flash("Nouveau pseudo et motif requis.", "error"); return; }
    const { error } = await supabaseClient.rpc("force_rename_player", { p_target: id, p_new_username: newName, p_reason: reason, p_client_ip: await ip });
    if (error) flash(error.message, "error"); else { await loadPlayers(); reload(); }
  });

  document.getElementById("noteBtn").addEventListener("click", async () => {
    const note = document.getElementById("newNote").value.trim();
    if (!note) return;
    const { error } = await supabaseClient.rpc("add_player_note", { p_target: id, p_note: note });
    if (error) flash(error.message, "error"); else reload();
  });

  document.querySelectorAll("[data-undo]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const { error } = await supabaseClient.rpc("undo_coin_adjustment", { p_audit_id: btn.dataset.undo });
      if (error) flash(error.message, "error"); else { await loadPlayers(); reload(); }
    });
  });

  const coinBtn = document.getElementById("coinBtn");
  if (coinBtn) coinBtn.addEventListener("click", async () => {
    const delta = parseInt(document.getElementById("coinDelta").value, 10);
    const reason = reasonOf("coin");
    if (!delta || !reason){ flash("Delta et motif requis.", "error"); return; }
    const { error } = await supabaseClient.rpc("adjust_player_coins", { p_target: id, p_delta: delta, p_reason: reason, p_client_ip: await ip });
    if (error) flash(error.message, "error"); else { await loadPlayers(); reload(); }
  });

  const suspendBtn = document.getElementById("suspendBtn");
  if (suspendBtn) suspendBtn.addEventListener("click", async () => {
    const reason = reasonOf("suspend");
    if (!reason){ flash("Motif requis.", "error"); return; }
    const { error } = await supabaseClient.rpc("set_player_suspended", { p_target: id, p_suspended: !p.suspended, p_reason: reason, p_client_ip: await ip });
    if (error) flash(error.message, "error"); else { await loadPlayers(); reload(); }
  });

  const vipBtn = document.getElementById("vipBtn");
  if (vipBtn) vipBtn.addEventListener("click", async () => {
    const reason = reasonOf("vip");
    if (!reason){ flash("Motif requis.", "error"); return; }
    const { error } = await supabaseClient.rpc("grant_player_vip", { p_target: id, p_vip: !p.vip, p_reason: reason, p_client_ip: await ip });
    if (error) flash(error.message, "error"); else { await loadPlayers(); reload(); }
  });

  const transferBtn = document.getElementById("transferBtn");
  if (transferBtn) transferBtn.addEventListener("click", async () => {
    const cardId = document.getElementById("tCardId").value.trim();
    const shiny = document.getElementById("tShiny").checked;
    const count = parseInt(document.getElementById("tCount").value, 10) || 1;
    const toUsername = document.getElementById("tToUsername").value.trim();
    const reason = reasonOf("transfer");
    if (!cardId || !toUsername || !reason){ flash("Carte, destinataire et motif requis.", "error"); return; }
    const { data: target, error: e1 } = await supabaseClient
      .from("profiles").select("id").ilike("username", toUsername).single();
    if (e1 || !target){ flash("Destinataire introuvable.", "error"); return; }
    const { error } = await supabaseClient.rpc("transfer_card", {
      p_from: id, p_to: target.id, p_card_id: cardId, p_shiny: shiny, p_count: count, p_reason: reason, p_client_ip: await ip
    });
    if (error) flash(error.message, "error"); else { flash("Carte transférée."); reload(); }
  });

  const deleteBtn = document.getElementById("deleteBtn");
  if (deleteBtn) deleteBtn.addEventListener("click", async () => {
    const reason = reasonOf("delete");
    const confirmName = document.getElementById("deleteConfirm").value.trim();
    if (!reason || confirmName !== p.username){ flash("Motif requis et pseudo à retaper exactement.", "error"); return; }
    const { error } = await supabaseClient.rpc("delete_player_account", { p_target: id, p_reason: reason, p_confirm_username: confirmName, p_client_ip: await ip });
    if (error) flash(error.message, "error"); else { document.getElementById("playerDlg").close(); await loadPlayers(); }
  });
}

// ===== Signalements =====

async function loadReports(){
  const { data, error } = await supabaseClient.rpc("list_reports", { p_status: "pending" });
  const list = document.getElementById("reportsList");
  if (error){ list.innerHTML = esc(error.message); return; }
  if (!data || !data.length){ list.innerHTML = admEmptyState("✓", "Aucun signalement en attente", "La file se remplit automatiquement dès qu'un joueur signale un message."); return; }
  list.innerHTML = data.map(r =>
    '<div class="reportcard" data-report="' + r.id + '">' +
      '<div class="rhead"><span>Signalé par ' + esc(r.reporter_username) + ' · ' + fmtDate(r.created_at) + '</span><span>Expéditeur : ' + esc(r.sender_username) + '</span></div>' +
      '<div><b>Motif :</b> ' + esc(r.reason) + '</div>' +
      '<div class="rmsg">' + esc(r.message_content) + '</div>' +
      '<div class="ractions">' +
        '<button class="btn" data-action="resolve" data-id="' + r.id + '" type="button">Marquer résolu</button>' +
        '<input type="text" class="pdlg-reason" data-mute-reason="' + r.sender_id + '" placeholder="Motif du mute" style="width:160px">' +
        '<button class="btn" data-action="mute" data-id="' + r.sender_id + '" type="button">Muter l\'expéditeur</button>' +
        '<button class="linklike" data-action="open" data-id="' + r.sender_id + '" type="button">Voir la fiche</button>' +
      '</div>' +
    '</div>'
  ).join("");

  list.querySelectorAll("[data-action]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const action = btn.dataset.action, id = btn.dataset.id;
      if (action === "resolve"){
        const { error } = await supabaseClient.rpc("resolve_report", { p_report_id: id });
        if (error) flash(error.message, "error"); else loadReports();
      } else if (action === "mute"){
        const reasonInput = list.querySelector('[data-mute-reason="' + id + '"]');
        const reason = (reasonInput ? reasonInput.value : "").trim();
        if (!reason){ flash("Motif requis.", "error"); return; }
        const { error } = await supabaseClient.rpc("set_player_muted", { p_target: id, p_muted: true, p_reason: reason, p_client_ip: await getClientIp() });
        if (error) flash(error.message, "error"); else flash("Joueur muté.");
      } else if (action === "open"){
        openPlayerCard(id);
      }
    });
  });

  const url = new URL(window.location.href);
  const focusId = url.searchParams.get("report");
  if (focusId){
    const el = list.querySelector('[data-report="' + focusId + '"]');
    if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
  }
}

// ===== Support (073_support_tickets.sql) =====

async function refreshSupportBadge(){
  const { data: count } = await supabaseClient.rpc("count_open_support_tickets");
  const badge = document.getElementById("supportBadge");
  if (count > 0){ badge.hidden = false; badge.textContent = count; }
  else badge.hidden = true;
}

async function loadSupportTickets(){
  const status = document.getElementById("supportStatusFilter").value;
  const { data, error } = await supabaseClient.rpc("list_support_tickets", { p_status: status });
  const list = document.getElementById("supportList");
  refreshSupportBadge();
  if (error){ list.innerHTML = esc(error.message); return; }
  if (!data || !data.length){ list.innerHTML = admEmptyState("💬", "Rien ici", "Aucun ticket dans ce statut pour l'instant."); return; }
  list.innerHTML = data.map(t =>
    '<div class="reportcard">' +
      '<div class="rhead"><span>' + esc(t.username) + ' · ' + fmtDate(t.created_at) + '</span><span>' + esc(t.status) + '</span></div>' +
      '<div><b>' + esc(t.subject) + '</b></div>' +
      '<div class="rmsg">' + esc(t.message) + '</div>' +
      (t.staff_note ? '<div class="rmsg"><b>Note équipe :</b> ' + esc(t.staff_note) + '</div>' : '') +
      (t.status !== 'closed' ? (
        '<div class="ractions">' +
          '<input type="text" class="pdlg-reason" data-note="' + t.id + '" placeholder="Note interne (optionnel)" style="width:220px">' +
          '<button class="btn" data-action="progress" data-id="' + t.id + '" type="button">En cours</button>' +
          '<button class="btn primary" data-action="close" data-id="' + t.id + '" type="button">Fermer</button>' +
        '</div>'
      ) : "") +
    '</div>'
  ).join("");

  list.querySelectorAll("[data-action]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.id;
      const noteInput = list.querySelector('[data-note="' + id + '"]');
      const note = noteInput ? noteInput.value.trim() || null : null;
      const status = btn.dataset.action === "close" ? "closed" : "in_progress";
      const { error: e2 } = await supabaseClient.rpc("resolve_support_ticket", { p_id: id, p_status: status, p_staff_note: note });
      if (e2) flash(e2.message, "error"); else loadSupportTickets();
    });
  });
}

// ===== Catalogue : grille façon Collection (vraies cartes cardHTML()) + gros éditeur =====
// Retour Doktor 29/09/2026 (2e vague) : pas juste une recherche par card_id — parcourir le
// catalogue comme la page Collection, choisir une carte manuellement, et dans un gros panneau
// ajuster l'image (aperçu en direct, cadrage par flèches, zoom), la rareté, l'ATK, le DEF.

const PLACEHOLDER_IMG = "assets/card-image-placeholder.png";
// Motifs rapides proposés au-dessus du champ libre (retour Doktor : "3/4 mots suffisent") — clic
// = pré-remplit le champ, toujours modifiable à la main ensuite.
const CAT_REASON_PRESETS = ["Recadrage", "Image corrigée", "Rareté ajustée", "Équilibrage stats"];
let catOffset = 0;
const CAT_PAGE_SIZE = 60;
let catEditState = null; // objet carte en cours d'édition dans le gros panneau

async function refreshImagesBadge(){
  const { data: count } = await supabaseClient.rpc("count_open_image_requests");
  const badge = document.getElementById("imagesBadge");
  if (count > 0){ badge.hidden = false; badge.textContent = count; }
  else badge.hidden = true;
}

async function loadCatalogueGrid(resetOffset){
  if (resetOffset) catOffset = 0;
  const search = document.getElementById("catSearch").value.trim() || null;
  const { data, error } = await supabaseClient.rpc("browse_catalogue_cards", { p_search: search, p_limit: CAT_PAGE_SIZE, p_offset: catOffset });
  const grid = document.getElementById("catGrid");
  refreshImagesBadge();
  if (error){ grid.innerHTML = esc(error.message); return; }
  if (!data || !data.length){
    grid.innerHTML = admEmptyState("🔍", "Aucune carte ne correspond", "Essaie un autre titre.");
    document.getElementById("catPager").innerHTML = "";
    return;
  }
  grid.innerHTML = data.map(c =>
    '<button class="catcell" type="button" data-cardid="' + esc(c.card_id) + '" title="' + esc(c.title) + '">' +
      '<div class="cw">' + cardHTML(c, {}) + '</div>' +
    '</button>'
  ).join("");
  window._catCache = {}; data.forEach(c => window._catCache[c.card_id] = c);

  grid.querySelectorAll("[data-cardid]").forEach(btn => {
    btn.addEventListener("click", () => openCatalogueEditor(window._catCache[btn.dataset.cardid]));
  });

  const pager = document.getElementById("catPager");
  pager.innerHTML =
    '<button class="btn" id="catPrevBtn" type="button"' + (catOffset === 0 ? " disabled" : "") + '>‹ Précédent</button>' +
    '<span class="pagesub" style="margin:0">' + (catOffset + 1) + '–' + (catOffset + data.length) + '</span>' +
    '<button class="btn" id="catNextBtn" type="button"' + (data.length < CAT_PAGE_SIZE ? " disabled" : "") + '>Suivant ›</button>';
  document.getElementById("catPrevBtn").addEventListener("click", () => { catOffset = Math.max(0, catOffset - CAT_PAGE_SIZE); loadCatalogueGrid(false); });
  document.getElementById("catNextBtn").addEventListener("click", () => { catOffset += CAT_PAGE_SIZE; loadCatalogueGrid(false); });
}

async function loadQueueIntoEditor(){
  const { data: count } = await supabaseClient.rpc("count_pending_image_reviews");
  document.getElementById("catQueueCount").textContent = (count ?? "—") + " carte(s) restant à trier dans le catalogue.";
  const { data, error } = await supabaseClient.rpc("get_next_image_review_card");
  if (error){ flash(error.message, "error"); return; }
  if (!data){ flash("Toutes les cartes sont validées. 🎉"); return; }
  openCatalogueEditor(data, true);
}

// Probe client : vérifie qu'une URL charge vraiment une image avant de l'enregistrer (retour
// Doktor : "le système doit détecter si le lien est bien pris en compte"). onload/onerror d'un
// <img> fonctionnent cross-origin sans souci CORS (contrairement à la lecture de pixels).
function probeImageUrl(url){
  return new Promise((resolve) => {
    if (!url){ resolve(false); return; }
    const img = new Image();
    const t = setTimeout(() => resolve(false), 8000);
    img.onload = () => { clearTimeout(t); resolve(true); };
    img.onerror = () => { clearTimeout(t); resolve(false); };
    img.src = url;
  });
}

function openCatalogueEditor(card, fromQueue){
  catEditState = Object.assign({
    image_pos_x: 50, image_pos_y: 35, image_scale: 1, atk: 0, def: 0, rarity: 0,
    rarity_name: "Commune", rarity_color: "#7d879c", family_color: "#7d879c",
  }, card);
  catEditState._fromQueue = !!fromQueue;
  renderCatalogueEditor();
  document.getElementById("catalogDlg").showModal();
}

function renderCatalogueEditor(){
  const c = catEditState;
  const rarityOptions = RARITY_ORDER.map((r, i) =>
    '<option value="' + i + '"' + (c.rarity === i ? " selected" : "") + '>' + esc(r.name) + '</option>'
  ).join("");
  const requestNote = c.request_count > 0
    ? '<p class="catreq">🚩 Signalée ' + c.request_count + ' fois par des joueurs.</p>' : "";

  document.getElementById("catalogDlgBody").innerHTML =
    '<div class="pdlg-head"><h2>' + esc(c.title) + '</h2><span class="rolebadge" style="width:auto">' + esc(c.card_id) + '</span></div>' +
    requestNote +
    '<div class="cateditor">' +
      '<div class="catpreview"><div class="cw" id="catPreviewCw">' + cardHTML(c, {}) + '</div></div>' +
      '<div class="catcontrols">' +
        '<div class="pdlg-section"><h3>Cadrage de l\'image</h3>' +
          '<div class="framectl">' +
            '<div class="dpad">' +
              '<span></span><button class="dbtn" type="button" data-dir="up">▲</button><span></span>' +
              '<button class="dbtn" type="button" data-dir="left">◀</button>' +
              '<button class="dbtn dbtn-reset" type="button" id="catFrameReset" title="Réinitialiser le cadrage">⟲</button>' +
              '<button class="dbtn" type="button" data-dir="right">▶</button>' +
              '<span></span><button class="dbtn" type="button" data-dir="down">▼</button><span></span>' +
            '</div>' +
            '<div class="zoomrow">' +
              '<button class="dbtn" type="button" id="catZoomMinus">−</button>' +
              '<span id="catZoomVal">' + Number(c.image_scale).toFixed(2) + '×</span>' +
              '<button class="dbtn" type="button" id="catZoomPlus">+</button>' +
            '</div>' +
          '</div>' +
        '</div>' +
        '<div class="pdlg-section"><h3>Image</h3>' +
          '<input type="text" id="catImgUrl" class="pdlg-txt" style="width:100%" placeholder="URL de l\'image" value="' + esc(c.image_url || "") + '">' +
          '<div class="pdlg-actionrow" style="margin-top:.5rem">' +
            '<span id="catImgStatus" class="catimgstatus"></span>' +
            '<button class="btn" type="button" id="catUsePlaceholder">Utiliser l\'image temporaire</button>' +
          '</div>' +
        '</div>' +
        '<div class="pdlg-section"><h3>Statistiques</h3>' +
          '<div class="pdlg-actionrow">' +
            '<select id="catRarity" class="pdlg-txt">' + rarityOptions + '</select>' +
            '<input type="number" id="catAtk" class="pdlg-num" style="width:90px" placeholder="ATK" value="' + c.atk + '">' +
            '<input type="number" id="catDef" class="pdlg-num" style="width:90px" placeholder="DEF" value="' + c.def + '">' +
          '</div>' +
        '</div>' +
        '<div class="pdlg-section">' +
          '<div class="motifchips">' +
            CAT_REASON_PRESETS.map(m => '<button class="chip" type="button" data-motif="' + esc(m) + '">' + esc(m) + '</button>').join("") +
          '</div>' +
          '<div class="pdlg-actionrow">' +
            '<input type="text" id="catReason" class="pdlg-reason" placeholder="Motif (optionnel)">' +
            '<button class="btn primary" type="button" id="catSaveBtn">Enregistrer</button>' +
          '</div>' +
          (c._fromQueue ? '<div class="pdlg-actionrow">' +
            '<button class="btn primary" type="button" id="catDoneBtn">✅ Fait — carte validée</button>' +
            '<button class="btn" type="button" id="catSkipBtn">⏭️ Passer — revoir plus tard</button>' +
          '</div>' : '') +
        '</div>' +
      '</div>' +
    '</div>';

  wireCatalogueEditor();
}

function redrawCatPreview(){
  document.getElementById("catPreviewCw").innerHTML = cardHTML(catEditState, {});
}

function wireCatalogueEditor(){
  const c = catEditState;

  document.querySelectorAll(".dbtn").forEach(btn => {
    btn.addEventListener("click", () => {
      const step = 4;
      if (btn.dataset.dir === "up") c.image_pos_y = Math.max(0, c.image_pos_y - step);
      if (btn.dataset.dir === "down") c.image_pos_y = Math.min(100, c.image_pos_y + step);
      if (btn.dataset.dir === "left") c.image_pos_x = Math.max(0, c.image_pos_x - step);
      if (btn.dataset.dir === "right") c.image_pos_x = Math.min(100, c.image_pos_x + step);
      redrawCatPreview();
    });
  });

  document.getElementById("catZoomMinus").addEventListener("click", () => {
    c.image_scale = Math.max(0.5, Math.round((c.image_scale - 0.1) * 100) / 100);
    document.getElementById("catZoomVal").textContent = c.image_scale.toFixed(2) + "×";
    redrawCatPreview();
  });
  document.getElementById("catZoomPlus").addEventListener("click", () => {
    c.image_scale = Math.min(3, Math.round((c.image_scale + 0.1) * 100) / 100);
    document.getElementById("catZoomVal").textContent = c.image_scale.toFixed(2) + "×";
    redrawCatPreview();
  });
  document.getElementById("catFrameReset").addEventListener("click", () => {
    c.image_pos_x = 50; c.image_pos_y = 35; c.image_scale = 1;
    document.getElementById("catZoomVal").textContent = "1.00×";
    redrawCatPreview();
  });

  const urlInput = document.getElementById("catImgUrl");
  const statusEl = document.getElementById("catImgStatus");
  let debounceT = null;
  urlInput.addEventListener("input", () => {
    clearTimeout(debounceT);
    statusEl.textContent = "…";
    statusEl.className = "catimgstatus";
    debounceT = setTimeout(async () => {
      const url = urlInput.value.trim();
      c.image_url = url;
      redrawCatPreview();
      const ok = await probeImageUrl(url);
      statusEl.textContent = ok ? "✓ image chargée" : "✕ lien mort ou invalide";
      statusEl.className = "catimgstatus " + (ok ? "ok" : "error");
    }, 400);
  });

  document.getElementById("catUsePlaceholder").addEventListener("click", () => {
    urlInput.value = PLACEHOLDER_IMG;
    urlInput.dispatchEvent(new Event("input"));
  });

  document.getElementById("catRarity").addEventListener("change", (e) => {
    const idx = parseInt(e.target.value, 10);
    c.rarity = idx; c.rarity_name = RARITY_ORDER[idx].name; c.rarity_color = RARITY_ORDER[idx].color;
    redrawCatPreview();
  });
  document.getElementById("catAtk").addEventListener("input", (e) => { c.atk = parseInt(e.target.value, 10) || 0; redrawCatPreview(); });
  document.getElementById("catDef").addEventListener("input", (e) => { c.def = parseInt(e.target.value, 10) || 0; redrawCatPreview(); });

  document.querySelectorAll(".motifchips [data-motif]").forEach(chip => {
    chip.addEventListener("click", () => { document.getElementById("catReason").value = chip.dataset.motif; });
  });

  document.getElementById("catSaveBtn").addEventListener("click", async () => {
    const reason = document.getElementById("catReason").value.trim() || null;
    const { error } = await supabaseClient.rpc("update_card_catalogue_entry", {
      p_card_id: c.card_id, p_image_url: c.image_url, p_rarity: c.rarity, p_atk: c.atk, p_def: c.def,
      p_image_pos_x: c.image_pos_x, p_image_pos_y: c.image_pos_y, p_image_scale: c.image_scale, p_reason: reason,
    });
    if (error){ flash(error.message, "error"); return; }
    flash("Carte enregistrée.");
  });

  const doneBtn = document.getElementById("catDoneBtn");
  if (doneBtn) doneBtn.addEventListener("click", async () => {
    const { error } = await supabaseClient.rpc("update_card_catalogue_entry", {
      p_card_id: c.card_id, p_image_url: c.image_url, p_rarity: c.rarity, p_atk: c.atk, p_def: c.def,
      p_image_pos_x: c.image_pos_x, p_image_pos_y: c.image_pos_y, p_image_scale: c.image_scale, p_reason: "Triage catalogue",
    });
    if (error){ flash(error.message, "error"); return; }
    await supabaseClient.rpc("set_image_review_status", { p_card_id: c.card_id, p_status: "done" });
    document.getElementById("catalogDlg").close();
    refreshImagesBadge();
    loadQueueIntoEditor();
  });
  const skipBtn = document.getElementById("catSkipBtn");
  if (skipBtn) skipBtn.addEventListener("click", async () => {
    await supabaseClient.rpc("set_image_review_status", { p_card_id: c.card_id, p_status: "skipped" });
    document.getElementById("catalogDlg").close();
    loadQueueIntoEditor();
  });
}

// ===== Annonces =====

async function loadAnnouncements(){
  const { data, error } = await supabaseClient
    .from("announcements").select("id, message, author_id, created_at").eq("active", true).order("created_at", { ascending: false });
  const list = document.getElementById("annList");
  if (error){ list.innerHTML = esc(error.message); return; }
  if (!data || !data.length){ list.innerHTML = admEmptyState("📣", "Aucune annonce active", "Publie un message ci-dessus pour qu'il apparaisse à tous les joueurs."); return; }
  list.innerHTML = data.map(a =>
    '<div class="reportcard">' +
      '<div class="rmsg">' + esc(a.message) + '</div>' +
      '<div class="rhead"><span>Publiée le ' + fmtDate(a.created_at) + '</span></div>' +
      '<div class="ractions"><button class="btn danger" data-deact="' + a.id + '" type="button">Retirer</button></div>' +
    '</div>'
  ).join("");
  list.querySelectorAll("[data-deact]").forEach(btn => {
    btn.addEventListener("click", async () => {
      const { error: e2 } = await supabaseClient.rpc("deactivate_announcement", { p_id: btn.dataset.deact });
      if (e2) flash(e2.message, "error"); else loadAnnouncements();
    });
  });
}

// ===== Init =====

(async function initAdmin(){
  const s = await requireSession();
  if (!s) return;
  const role = await checkStaffRole();
  if (!role) return;

  setupTabs();
  document.getElementById("elevSubmit").addEventListener("click", submitElevation);
  document.getElementById("elevPassword").addEventListener("keydown", (e) => { if (e.key === "Enter") submitElevation(); });

  document.getElementById("playersBody").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-id]");
    if (btn) openPlayerCard(btn.dataset.id);
  });
  document.getElementById("playerSearchBtn").addEventListener("click", loadPlayers);
  document.getElementById("cardOwnerBtn").addEventListener("click", searchCardOwners);
  document.getElementById("exportCsvBtn").addEventListener("click", exportPlayersCsv);
  document.getElementById("catSearchBtn").addEventListener("click", () => loadCatalogueGrid(true));
  document.getElementById("catSearch").addEventListener("keydown", (e) => { if (e.key === "Enter") loadCatalogueGrid(true); });
  document.getElementById("catQueueBtn").addEventListener("click", loadQueueIntoEditor);
  document.getElementById("supportFilterBtn").addEventListener("click", loadSupportTickets);
  document.getElementById("playerDlgClose").addEventListener("click", () => document.getElementById("playerDlg").close());
  document.getElementById("catalogDlgClose").addEventListener("click", () => document.getElementById("catalogDlg").close());
  document.getElementById("annCreateBtn").addEventListener("click", async () => {
    const msg = document.getElementById("annMessage").value.trim();
    if (!msg) return;
    const { error } = await supabaseClient.rpc("create_announcement", { p_message: msg });
    if (error) flash(error.message, "error"); else { document.getElementById("annMessage").value = ""; loadAnnouncements(); }
  });

  await tryResumeElevation();
})();
