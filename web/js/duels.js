/* Duels contre l'ordinateur — run_duel() (035_rpc_run_duel.sql). Deck de 5 cartes possédées,
   chacune comparée à un adversaire tiré au hasard dans card_catalogue à la même rareté. */

const DUEL_CAP = 5;
let myCollection = [];
let deckPick = [];

async function loadMyCollection(){
  const { data } = await supabaseClient
    .from("collection")
    .select("card_id, shiny, count, card_catalogue(" + CARD_FIELDS + ")")
    .eq("profile_id", session.user.id)
    .order("card_id");
  myCollection = (data || []).filter(r => r.card_catalogue);
  renderDeckGrid();
}

function renderDeckGrid(){
  const grid = document.getElementById("deckGrid");
  grid.innerHTML = myCollection.length ? myCollection.map(row => {
    const g = row.card_catalogue;
    const sel = deckPick.includes(row.card_id);
    return '<button class="deckpick' + (sel ? " on" : "") + '" type="button" data-id="' + esc(row.card_id) + '" aria-pressed="' + sel + '">' +
      cardBlockHTML(g, row.shiny, {}) + '</button>';
  }).join("") : '<p class="empty">Tu n\'as pas encore de carte à aligner.</p>';
}

document.getElementById("deckGrid").addEventListener("click", (e) => {
  const b = e.target.closest("[data-id]");
  if (!b) return;
  const id = b.dataset.id;
  const ix = deckPick.indexOf(id);
  if (ix >= 0) deckPick.splice(ix, 1);
  else if (deckPick.length >= 5){ toast("5 cartes maximum dans ton deck."); return; }
  else deckPick.push(id);
  renderDeckGrid();
  const btn = document.getElementById("runDuelBtn");
  btn.disabled = deckPick.length !== 5;
  btn.textContent = "Lancer le duel (" + deckPick.length + " / 5)";
});

async function loadCap(){
  const { data } = await supabaseClient
    .from("player_state")
    .select("duel_date, duels_played_today, duel_wins_total")
    .eq("profile_id", session.user.id)
    .single();
  const today = new Date().toDateString();
  const sameDay = data && data.duel_date && new Date(data.duel_date).toDateString() === today;
  const played = sameDay ? data.duels_played_today : 0;
  const left = Math.max(0, DUEL_CAP - played);
  document.getElementById("duelCapStatus").textContent =
    "Duels restants aujourd'hui : " + left + " / " + DUEL_CAP +
    (data && data.duel_wins_total ? " · Victoires totales : " + data.duel_wins_total : "");
  document.getElementById("duelBuildPanel").hidden = left <= 0;
  return left;
}

function roundHTML(r){
  const cls = r.result === "win" ? "win" : (r.result === "lose" ? "lose" : "");
  const arrow = r.result === "win" ? "▲" : (r.result === "lose" ? "▼" : "=");
  return '<div class="duelround ' + cls + '"><span>' + esc(r.my_title) + '<br><small>ATK ' + fmt(r.my_atk) + '</small></span>' +
    '<span class="vs">' + arrow + '</span>' +
    '<span class="side2">' + esc(r.opp_title) + '<br><small>DEF ' + fmt(r.opp_def) + '</small></span></div>';
}

function renderDuelResult(d){
  const panel = document.getElementById("duelResultPanel");
  panel.hidden = false;
  document.getElementById("duelResultBody").innerHTML =
    '<p class="duelresult ' + (d.won ? "won" : "lost") + '">' + (d.won ? "Victoire !" : "Défaite") + ' (' + d.my_wins + ' - ' + d.their_wins + ')</p>' +
    '<div class="duelrounds">' + d.rounds.map(roundHTML).join("") + '</div>' +
    '<p class="sub">+' + fmt(d.reward) + ' pièces' + (d.won ? "" : " (participation)") + '.</p>';
}

document.getElementById("runDuelBtn").addEventListener("click", async () => {
  if (deckPick.length !== 5) return;
  const btn = document.getElementById("runDuelBtn");
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc("run_duel", { p_deck: deckPick });
  if (error){ showMsg("duelMsg", error.message, "error"); btn.disabled = deckPick.length !== 5; return; }
  document.getElementById("duelMsg").className = "msg";
  deckPick = [];
  renderDeckGrid();
  btn.textContent = "Lancer le duel (0 / 5)";
  renderDuelResult(data);
  await refreshHud();
  await loadCap();
  await loadHistory();
  window.scrollTo({ top: 0, behavior: "smooth" });
});

async function loadHistory(){
  const { data, error } = await supabaseClient
    .from("duel_history")
    .select("id, won, my_wins, their_wins, reward, created_at")
    .eq("profile_id", session.user.id)
    .order("created_at", { ascending: false })
    .limit(30);
  if (error){ document.getElementById("duelHistStatus").textContent = "Erreur : " + error.message; return; }
  const rows = data || [];
  document.getElementById("duelHistStatus").textContent = rows.length ? "" : "Aucun duel pour l'instant.";
  document.getElementById("duelHistList").innerHTML = rows.map(d =>
    '<div class="duelhistrow"><span>' + new Date(d.created_at).toLocaleString("fr-FR") + ' — ' +
    (d.won ? "Victoire" : "Défaite") + ' (' + d.my_wins + ' - ' + d.their_wins + ')</span>' +
    '<span>+' + fmt(d.reward) + '<span class="coin" aria-hidden="true"></span></span></div>'
  ).join("");
}

async function loadFromId(id){
  const { data, error } = await supabaseClient
    .from("duel_history")
    .select("won, my_wins, their_wins, reward, rounds")
    .eq("id", id)
    .single();
  if (error || !data) return;
  renderDuelResult(data);
  window.scrollTo({ top: 0, behavior: "smooth" });
}

(async function(){
  if (!(await initPage())) return;
  await loadMyCollection();
  await loadCap();
  await loadHistory();

  const id = new URLSearchParams(window.location.search).get("id");
  if (id) await loadFromId(id);
})();
