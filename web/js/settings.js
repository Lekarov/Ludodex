function showMsg(id, text, kind){
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = "msg show " + kind;
}

let currentProfile = null;

// Groupé par catégorie pour la lisibilité (11 types à plat serait une longue liste sans repère) ;
// la clé est le `type` exact inséré par create_notification() côté serveur (voir notifIcon() dans
// notifications.js et 049_notification_preferences.sql). Absent de notif_prefs ou à `true` = activé
// (modèle opt-out, cohérent avec le défaut serveur).
const NOTIF_PREF_GROUPS = [
  { label: "Progression", types: [
    { type: "achievement", icon: "🏆", label: "Succès débloqué" },
    { type: "gold_unique", icon: "✨", label: "Carte Gold Unique obtenue" },
  ] },
  { label: "Marché", types: [
    { type: "outbid", icon: "⚠️", label: "Ta mise a été dépassée" },
    { type: "auction_won", icon: "🎉", label: "Enchère remportée" },
    { type: "listing_sold", icon: "💰", label: "Carte vendue" },
    { type: "wishlist_available", icon: "⭐", label: "Carte de ta liste de souhaits mise en vente" },
  ] },
  { label: "Social", types: [
    { type: "message", icon: "✉️", label: "Message privé reçu" },
    { type: "trade_offer", icon: "🔁", label: "Proposition d'échange reçue" },
    { type: "trade_accepted", icon: "🤝", label: "Échange accepté" },
    { type: "trade_declined", icon: "🔁", label: "Échange refusé" },
  ] },
  { label: "Duels", types: [
    { type: "duel_result", icon: "⚔️", label: "Résultat d'un duel" },
  ] },
];

function renderNotifPrefs(prefs){
  document.getElementById("notifPrefs").innerHTML = NOTIF_PREF_GROUPS.map(group =>
    '<div class="notifprefgroup"><h3>' + group.label + '</h3>' +
    group.types.map(t => {
      const enabled = prefs[t.type] !== false;
      return '<label class="switchrow" data-notif-type="' + t.type + '">' +
        '<div><b>' + t.icon + ' ' + t.label + '</b></div>' +
        '<span class="switch"><input type="checkbox" ' + (enabled ? "checked" : "") + '><i></i></span>' +
      '</label>';
    }).join("") +
    '</div>'
  ).join("");

  document.querySelectorAll("#notifPrefs [data-notif-type]").forEach(row => {
    row.querySelector("input").addEventListener("change", async (e) => {
      const type = row.dataset.notifType;
      const nextPrefs = { ...currentProfile.notif_prefs, [type]: e.target.checked };
      if (e.target.checked) delete nextPrefs[type]; // absent = activé, garde le JSON minimal
      const { data: { session } } = await supabaseClient.auth.getSession();
      const { error } = await supabaseClient.from("profiles").update({ notif_prefs: nextPrefs }).eq("id", session.user.id);
      if (error){ showMsg("settingsMsg", error.message, "error"); e.target.checked = !e.target.checked; return; }
      currentProfile.notif_prefs = nextPrefs;
    });
  });
}

async function loadSettings(){
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session){ window.location.href = "login.html"; return; }

  const { data: profile, error } = await supabaseClient
    .from("profiles")
    .select("collection_public, notif_prefs")
    .eq("id", session.user.id)
    .single();
  if (error){ showMsg("settingsMsg", "Impossible de charger le profil : " + error.message, "error"); return; }

  currentProfile = profile;
  document.getElementById("collectionPublic").checked = profile.collection_public;
  renderNotifPrefs(profile.notif_prefs || {});

  const { data: state } = await supabaseClient
    .from("player_state")
    .select("coins")
    .eq("profile_id", session.user.id)
    .single();
  if (state) document.getElementById("coins").textContent = state.coins;
}

document.getElementById("collectionPublic").addEventListener("change", async (e) => {
  const { data: { session } } = await supabaseClient.auth.getSession();
  const { error } = await supabaseClient
    .from("profiles")
    .update({ collection_public: e.target.checked })
    .eq("id", session.user.id);
  if (error){ showMsg("settingsMsg", error.message, "error"); e.target.checked = !e.target.checked; return; }
  showMsg("settingsMsg", e.target.checked ? "Ta collection est maintenant publique." : "Ta collection est maintenant privée.", "ok");
});

/* ===== Son : volume des bruitages (voir js/sfx.js), gardé en local sur cet appareil ===== */
const volInput = document.getElementById("sfxVolume");
const volVal = document.getElementById("sfxVolumeVal");
function syncVolumeUI(){
  const pct = Math.round(sfx.getVolume() * 100);
  volInput.value = pct;
  volVal.textContent = pct + "%";
}
syncVolumeUI();
volInput.addEventListener("input", () => {
  sfx.setVolume(volInput.value / 100);
  volVal.textContent = volInput.value + "%";
});
volInput.addEventListener("change", () => sfx.flip()); // aperçu du son au volume choisi

/* ===== Contacter le support (073_support_tickets.sql) ===== */
document.getElementById("supportSendBtn").addEventListener("click", async () => {
  const btn = document.getElementById("supportSendBtn");
  const subject = document.getElementById("supportSubject").value.trim();
  const message = document.getElementById("supportMessage").value.trim();
  if (!subject || !message){ showMsg("supportMsg", "Sujet et message requis.", "error"); return; }
  btn.disabled = true;
  const { error } = await supabaseClient.rpc("submit_support_ticket", { p_subject: subject, p_message: message });
  btn.disabled = false;
  if (error){ showMsg("supportMsg", error.message, "error"); return; }
  document.getElementById("supportSubject").value = "";
  document.getElementById("supportMessage").value = "";
  showMsg("supportMsg", "Message envoyé, l'équipe te répondra si besoin.", "ok");
});

/* ===== Export de mes données (RGPD, auto-service) ===== */
// Tout passe par les policies RLS déjà en place (chaque requête ne peut de toute façon renvoyer
// que les lignes qui appartiennent au joueur connecté) — pas besoin d'une fonction serveur dédiée.
// Volontairement exclu : notes internes de modération (player_notes) et journal d'audit
// (audit_log) — décision produit déjà actée que ces données restent internes à l'équipe, jamais
// visibles du joueur lui-même, y compris via cet export.
document.getElementById("exportDataBtn").addEventListener("click", async () => {
  const btn = document.getElementById("exportDataBtn");
  btn.disabled = true;
  showMsg("exportMsg", "Préparation de l'export…", "ok");

  const { data: { session } } = await supabaseClient.auth.getSession();
  const uid = session.user.id;

  const [
    profile, state, collection, tradesFrom, tradesTo, duels,
    messagesSent, messagesReceived, listings, bids, notifications, wishlist, blocks, imageReports,
  ] = await Promise.all([
    supabaseClient.from("profiles").select("*").eq("id", uid).single(),
    supabaseClient.from("player_state").select("*").eq("profile_id", uid).single(),
    supabaseClient.from("collection").select("card_id, shiny, count, obtained_at").eq("profile_id", uid),
    supabaseClient.from("trade_offers").select("*").eq("from_profile", uid),
    supabaseClient.from("trade_offers").select("*").eq("to_profile", uid),
    supabaseClient.from("duel_history").select("*").eq("profile_id", uid),
    supabaseClient.from("private_messages").select("*").eq("sender_id", uid),
    supabaseClient.from("private_messages").select("*").eq("recipient_id", uid),
    supabaseClient.from("market_listings").select("*").eq("seller_profile_id", uid),
    supabaseClient.from("market_bids").select("*").eq("bidder_profile_id", uid),
    supabaseClient.from("notifications").select("*").eq("profile_id", uid),
    supabaseClient.from("wishlist").select("card_id, created_at").eq("profile_id", uid),
    supabaseClient.from("blocks").select("blocked_id, created_at").eq("blocker_id", uid),
    supabaseClient.from("card_image_requests").select("card_id, comment, resolved, created_at").eq("reporter_id", uid),
  ]);

  const firstError = [profile, state, collection, tradesFrom, tradesTo, duels, messagesSent, messagesReceived,
    listings, bids, notifications, wishlist, blocks, imageReports].find(r => r.error);
  if (firstError){ showMsg("exportMsg", "Erreur : " + firstError.error.message, "error"); btn.disabled = false; return; }

  const bundle = {
    export_genere_le: new Date().toISOString(),
    profil: profile.data,
    etat_de_jeu: state.data,
    collection: collection.data,
    echanges_envoyes: tradesFrom.data,
    echanges_recus: tradesTo.data,
    duels: duels.data,
    messages_envoyes: messagesSent.data,
    messages_recus: messagesReceived.data,
    annonces_marche: listings.data,
    encheres_placees: bids.data,
    notifications: notifications.data,
    liste_de_souhaits: wishlist.data,
    joueurs_bloques: blocks.data,
    signalements_image_envoyes: imageReports.data,
  };

  const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "ludodex-mes-donnees-" + new Date().toISOString().slice(0, 10) + ".json";
  a.click();
  URL.revokeObjectURL(a.href);

  showMsg("exportMsg", "Export téléchargé.", "ok");
  btn.disabled = false;
});

// Suppression de compte : confirmation par saisie du mot "SUPPRIMER" avant d'activer le bouton,
// pour une action immédiate et irréversible (voir delete_own_account() côté serveur).
const deleteDlg = document.getElementById("deleteDlg");
document.getElementById("openDeleteBtn").addEventListener("click", () => {
  document.getElementById("confirmDeleteInput").value = "";
  document.getElementById("confirmDeleteBtn").disabled = true;
  document.getElementById("deleteMsg").className = "msg";
  deleteDlg.showModal();
});
document.getElementById("cancelDeleteBtn").addEventListener("click", () => deleteDlg.close());
document.getElementById("confirmDeleteInput").addEventListener("input", (e) => {
  document.getElementById("confirmDeleteBtn").disabled = e.target.value.trim().toUpperCase() !== "SUPPRIMER";
});
document.getElementById("confirmDeleteBtn").addEventListener("click", async () => {
  const btn = document.getElementById("confirmDeleteBtn");
  btn.disabled = true;
  showMsg("deleteMsg", "Suppression en cours…", "ok");
  const { error } = await supabaseClient.rpc("delete_own_account");
  if (error){ showMsg("deleteMsg", error.message, "error"); btn.disabled = false; return; }
  await supabaseClient.auth.signOut();
  window.location.href = "login.html";
});

loadSettings();
