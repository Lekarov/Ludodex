/* ===== Succès ===== */
// Métadonnées d'affichage (nom, description, catégorie, objectif, récompense) — la seule vérité
// sur "qui a débloqué quoi" et "combien ça rapporte" reste côté serveur (021_rpc_achievements.sql),
// ceci ne sert qu'à afficher une barre de progression cohérente sans dupliquer la logique SQL.
const ACH = [
  { id: "b1", cat: "Boosters", n: "Premier booster", d: "Ouvre ton premier booster", goal: 1, r: 10, key: "boosters_opened_total" },
  { id: "b10", cat: "Boosters", n: "Accro au papier", d: "Ouvre 10 boosters", goal: 10, r: 25, key: "boosters_opened_total" },
  { id: "b50", cat: "Boosters", n: "Déchireur", d: "Ouvre 50 boosters", goal: 50, r: 60, key: "boosters_opened_total" },
  { id: "b100", cat: "Boosters", n: "Centenaire", d: "Ouvre 100 boosters", goal: 100, r: 100, key: "boosters_opened_total" },
  { id: "b250", cat: "Boosters", n: "Usine à boosters", d: "Ouvre 250 boosters", goal: 250, r: 150, key: "boosters_opened_total" },
  { id: "gold", cat: "Boosters", n: "Or massif", d: "Ouvre un booster doré", goal: 1, r: 20, key: "golds_opened_total" },
  { id: "raf", cat: "Boosters", n: "Veinard", d: "Gagne une tombola (bientôt disponible)", goal: 1, r: 20, key: null },
  { id: "c10", cat: "Collection", n: "Petite étagère", d: "Possède 10 jeux différents", goal: 10, r: 20, key: "owned_distinct" },
  { id: "c25", cat: "Collection", n: "Collectionneur", d: "Possède 25 jeux différents", goal: 25, r: 40, key: "owned_distinct" },
  { id: "c50", cat: "Collection", n: "Ludothèque", d: "Possède 50 jeux différents", goal: 50, r: 80, key: "owned_distinct" },
  { id: "c100", cat: "Collection", n: "Musée du jeu vidéo", d: "Possède 100 jeux différents", goal: 100, r: 150, key: "owned_distinct" },
  { id: "call", cat: "Collection", n: "Ludodex complet", d: "Possède tous les jeux du catalogue", goal: null, r: 300, key: "owned_distinct", goalKey: "catalogue_total" },
  { id: "set1", cat: "Collection", n: "Set complet", d: "Complète toutes les cartes d'une plateforme", goal: 1, r: 60, key: "platforms_completed" },
  { id: "set5", cat: "Collection", n: "Maître des consoles", d: "Complète 5 plateformes", goal: 5, r: 150, key: "platforms_completed" },
  { id: "r2", cat: "Raretés", n: "Coup de chance", d: "Tire une carte Rare", goal: 1, r: 15, key: "pulls_rare" },
  { id: "r3", cat: "Raretés", n: "Épique !", d: "Tire une carte Épique", goal: 1, r: 30, key: "pulls_epic" },
  { id: "r4", cat: "Raretés", n: "Légende vivante", d: "Tire une carte Légendaire", goal: 1, r: 60, key: "pulls_legendary" },
  { id: "r5", cat: "Raretés", n: "Mythe", d: "Tire une carte Mythique", goal: 1, r: 120, key: "pulls_mythic" },
  { id: "sh1", cat: "Raretés", n: "Ça brille !", d: "Tire une carte brillante", goal: 1, r: 40, key: "shiny_drawn_total" },
  { id: "sh5", cat: "Raretés", n: "Boule à facettes", d: "Tire 5 cartes brillantes", goal: 5, r: 100, key: "shiny_drawn_total" },
  { id: "m1", cat: "Marché", n: "Premier achat", d: "Achète une carte au marché", goal: 1, r: 10, key: "bought_count" },
  { id: "m2", cat: "Marché", n: "Commerçant", d: "Vends une carte au marché", goal: 1, r: 15, key: "sold_count" },
  { id: "m10", cat: "Marché", n: "Marchand", d: "Vends 10 cartes au marché", goal: 10, r: 50, key: "sold_count" },
  { id: "win", cat: "Marché", n: "Adjugé !", d: "Remporte une enchère", goal: 1, r: 25, key: "auctions_won" },
  { id: "earn", cat: "Marché", n: "Magnat", d: "Gagne 1000 pièces grâce à tes ventes", goal: 1000, r: 75, key: "earned" },
];

async function loadStats(){
  document.getElementById("achSum").textContent = "Chargement…";
  const [{ data: progress, error: progErr }, { data: unlocked, error: unlErr }] = await Promise.all([
    supabaseClient.rpc("get_achievement_progress"),
    supabaseClient.from("achievements_unlocked").select("achievement_id, reward_granted").eq("profile_id", session.user.id),
  ]);
  if (progErr || unlErr){ document.getElementById("achSum").textContent = "Erreur de chargement."; console.error(progErr || unlErr); return; }

  const unlockedById = {};
  (unlocked || []).forEach(u => { unlockedById[u.achievement_id] = u.reward_granted; });

  const doneCount = Object.keys(unlockedById).length;
  const pending = ACH.filter(a => unlockedById[a.id] === false);
  const toGet = pending.reduce((s, a) => s + a.r, 0);

  document.getElementById("achSum").innerHTML =
    '<span><strong>' + doneCount + '</strong> / ' + ACH.length + ' débloqués</span>' +
    (pending.length ? '<button class="btn primary sm" type="button" id="claimAllBtn">Tout récupérer (+' + toGet + ')</button>' : "");
  document.getElementById("achProgressFill").style.width = (doneCount / ACH.length * 100) + "%";
  const claimAllBtn = document.getElementById("claimAllBtn");
  if (claimAllBtn) claimAllBtn.addEventListener("click", claimAchievements);

  let html = "", cat = "";
  for (const a of ACH){
    if (a.cat !== cat){ if (cat) html += "</div>"; cat = a.cat; html += '<h3 class="achcat">' + esc(a.cat) + '</h3><div class="achgrid">'; }
    const state = unlockedById[a.id]; // undefined = verrouillé, false = à récupérer, true = obtenu
    const val = a.key ? (progress[a.key] || 0) : 0;
    const goal = a.goalKey ? progress[a.goalKey] : a.goal;
    const cls = state === undefined ? "locked" : (state ? "done" : "claim");
    const action = state === true
      ? ""
      : state === false
        ? '<button class="btn primary sm" type="button" data-claim="' + a.id + '">Réclamer</button>'
        : (goal ? '<div class="achbar"><i style="width:' + (Math.min(val, goal) / goal * 100) + '%"></i></div><div class="achgoal">' + fmt(Math.min(val, goal)) + ' / ' + fmt(goal) + '</div>' : "");
    html += '<div class="achcard ' + cls + '">' +
      '<span class="achic" aria-hidden="true">' + (state !== undefined ? "★" : "☆") + '</span>' +
      '<div class="achbody">' +
        '<div class="achn">' + esc(a.n) + (state !== undefined ? '<span class="check">✓</span>' : "") + '</div>' +
        '<div class="achd">' + esc(a.d) + '</div>' +
        '<div class="achreward">+' + a.r + '<span class="coin" aria-hidden="true"></span></div>' +
        action +
      '</div></div>';
  }
  document.getElementById("achList").innerHTML = html + (cat ? "</div>" : "");
}

document.getElementById("achList").addEventListener("click", (e) => {
  const b = e.target.closest("[data-claim]");
  if (b) claimAchievements();
});

async function claimAchievements(){
  const { data, error } = await supabaseClient.rpc("sync_and_claim_achievements");
  if (error){ toast(error.message); return; }
  if (data.total_reward > 0){
    toast("+" + data.total_reward + " pièces récupérées");
    await refreshHud();
  }
  await loadStats();
}


(async function(){ if (!(await initPage())) return; await loadStats(); })();
