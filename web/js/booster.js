/* ===== Boosters : ouverture + révélation carte par carte (dos -> face) ===== */
let pack = null; // {res:[{g,sh}], seen, idx}
const RM = matchMedia("(prefers-reduced-motion: reduce)").matches;

function openPackAnimation(onReveal){
  const btn = document.getElementById("openBtn");
  btn.classList.remove("tearing");
  void btn.offsetWidth;
  btn.classList.add("tearing");
  sfx.press();
  sfx.tear();
  if (!RM){
    setTimeout(() => { const f = document.getElementById("flash"); f.classList.remove("go"); void f.offsetWidth; f.classList.add("go"); }, 650);
  }
  setTimeout(async () => {
    btn.classList.remove("tearing");
    await onReveal();
  }, RM ? 550 : 800);
}

async function revealDrawnCards(cards, goldPackMsg){
  const cardIds = cards.map(c => c.card_id);
  const { data: fetched, error: cardsErr } = await supabaseClient
    .from("card_catalogue")
    .select("card_id, " + CARD_FIELDS)
    .in("card_id", cardIds);
  if (cardsErr) console.error(cardsErr);
  const byId = {};
  (fetched || []).forEach(c => { byId[c.card_id] = c; });

  // La carte Gold unique (bonus, indépendant des 5 cartes normales — voir open_booster()) n'a ni
  // rareté ni brillance côté RPC, juste { card_id, gold: true } : on complète avec le rendu
  // normal de la carte, seul le flag `gold` change l'effet visuel à la révélation.
  const uniqueCard = cards.find(c => c.gold);
  if (uniqueCard && byId[uniqueCard.card_id]) toast("✨ Carte GOLD UNIQUE : " + byId[uniqueCard.card_id].title + " — tu es le seul à la posséder !");
  else if (goldPackMsg) toast(goldPackMsg);

  pack = { res: cards.map(c => ({ g: byId[c.card_id], sh: c.shiny, gold: !!c.gold })), seen: 1, idx: 0 };
  const total = document.getElementById("cTotal");
  if (total) total.textContent = pack.res.length;
  document.getElementById("packStage").hidden = true;
  document.getElementById("revealStage").hidden = false;
  window.scrollTo(0, 0);
  showCard(0, true);
}

function openBooster(){
  if (document.getElementById("openBtn").disabled) return;
  document.getElementById("openLbl").disabled = true;
  document.getElementById("openBtn").disabled = true;
  openPackAnimation(async () => {
    const { data, error } = await supabaseClient.rpc("open_booster");
    if (error){ toast(error.message); await refreshHud(); return; }
    await revealDrawnCards(data.cards, data.gold ? "✨ Booster doré !" : null);
    await refreshHud();
  });
}
document.getElementById("openBtn").addEventListener("click", openBooster);
document.getElementById("openLbl").addEventListener("click", openBooster);

/* ===== Boosters thématiques ===== */
// Métadonnées d'affichage (nom, emblème, couleurs) reprises de site/js/engine/raffle.js (THEMES) —
// le filtrage réel (quelles cartes appartiennent au thème) est fait côté serveur
// (025_themed_boosters.sql), ceci ne sert qu'à dessiner le mini-paquet.
const THEMES = [
  { id: "nintendo", n: "Nintendo", e: "N", c1: "#ff6b6e", c2: "#b8141a" },
  { id: "sony", n: "PlayStation", e: "P", c1: "#6f97ff", c2: "#1f3fa8" },
  { id: "sega", n: "Sega", e: "S", c1: "#6fd0ff", c2: "#0f6b9c" },
  { id: "xbox", n: "Xbox", e: "X", c1: "#7fd67f", c2: "#1f6b2a" },
  { id: "pc", n: "PC", e: "PC", c1: "#aab1c2", c2: "#3d4352" },
  { id: "retro", n: "Arcade et rétro", e: "A", c1: "#ffb36b", c2: "#a3500b" },
  { id: "y80", n: "Années 80", e: "80", c1: "#ff8fd8", c2: "#8a1f7a" },
  { id: "y90", n: "Années 90", e: "90", c1: "#ffd76a", c2: "#9a6a08" },
  { id: "y00", n: "Années 2000", e: "00", c1: "#8ff0d4", c2: "#127a5e" },
  { id: "y10", n: "Jeux récents", e: "10+", c1: "#c9a2ff", c2: "#5a2aa8" },
];

async function loadThemedTickets(){
  const { data, error } = await supabaseClient.rpc("get_themed_tickets");
  const list = document.getElementById("themedList");
  if (error || !data || Object.keys(data).length === 0){ list.hidden = true; return; }

  list.hidden = false;
  list.innerHTML = '<h2>Boosters thématiques</h2>' + Object.keys(data).map(themeId => {
    const t = THEMES.find(x => x.id === themeId);
    if (!t) return "";
    return '<button class="tpack" type="button" data-theme="' + t.id + '" style="--t1:' + t.c1 + ';--t2:' + t.c2 + '">' +
      '<span class="minipack">' + esc(t.e) + '</span><b>' + esc(t.n) + '</b><span>×' + data[themeId] + '</span></button>';
  }).join("");
}

document.getElementById("themedList").addEventListener("click", (e) => {
  const b = e.target.closest("[data-theme]");
  if (!b) return;
  const themeId = b.dataset.theme;
  b.disabled = true;
  openPackAnimation(async () => {
    const { data, error } = await supabaseClient.rpc("open_themed_booster", { p_theme_id: themeId });
    if (error){ toast(error.message); b.disabled = false; return; }
    await revealDrawnCards(data.cards, null);
    await loadThemedTickets();
  });
});

function goldFlash(){
  const f = document.getElementById("flash");
  f.classList.remove("go"); f.classList.add("gold");
  void f.offsetWidth; f.classList.add("go");
  setTimeout(() => f.classList.remove("gold"), 800);
}

function showCard(i, fresh){
  pack.idx = i;
  const x = pack.res[i];
  const el = document.getElementById("oneCard");
  if (x.g){
    // Active burst/shburst (card.css) pour les raretés hautes et les brillantes.
    el.dataset.r = x.g.rarity;
    el.dataset.sh = (x.sh || x.gold) ? "1" : "";
  }
  if (!x.g){
    el.innerHTML = '<div class="card"><div class="cc-body"><h4 class="cc-title">Carte inconnue</h4></div></div>';
  } else if (fresh){
    sfx.card(x.g.rarity);
    if (x.sh || x.gold) sfx.shiny();
    else if (x.g.rarity >= 3) sfx.chime(x.g.rarity);
    el.classList.remove("enter");
    el.innerHTML = '<div class="flipcard"><div class="flipface back cardback"></div><div class="flipface front">' + cardHTML(x.g, { shiny: x.sh, gold: x.gold }) + '</div></div>';
    const flip = el.querySelector(".flipcard");
    setTimeout(() => {
      flip.classList.add("flipped");
      sfx.flip();
      setTimeout(() => {
        el.classList.remove("enter");
        void el.offsetWidth;
        el.classList.add("enter");
        if ((x.sh || x.gold) && !RM) goldFlash();
      }, RM ? 300 : 800);
    }, 700);
  } else {
    el.innerHTML = cardHTML(x.g, { shiny: x.sh, gold: x.gold });
  }

  document.getElementById("cIdx").textContent = i + 1;
  document.getElementById("dots").innerHTML = pack.res.map((_, k) => '<i class="' + (k === i ? "cur" : (k < pack.seen ? "seen" : "")) + '"></i>').join("");
  document.getElementById("prevC").disabled = i === 0;
}

// Touche la carte -> fiche détail (même interface que Collection/Toutes les cartes, voir
// detail.js), façon WikiMasters : ce n'est plus le tap qui fait avancer, seules les flèches/points
// le font désormais. Le compte réel (pour le badge "+N" sur Défausser) est relu à la volée : les 5
// cartes d'un booster peuvent contenir des doublons entre elles ou avec la collection existante.
async function showPulledCardDetail(x){
  if (!x.g) return;
  const { data } = await supabaseClient
    .from("collection").select("count")
    .eq("profile_id", session.user.id).eq("card_id", x.g.card_id).eq("shiny", !!x.sh)
    .maybeSingle();
  openDetail(x.g.card_id, x.sh, x.g, (data && data.count) || 1);
}
document.getElementById("oneCard").addEventListener("click", () => {
  if (!pack) return;
  showPulledCardDetail(pack.res[pack.idx]);
});
document.getElementById("prevC").addEventListener("click", () => { if (pack && pack.idx > 0) showCard(pack.idx - 1, false); });
document.getElementById("nextC").addEventListener("click", () => {
  if (!pack) return;
  if (pack.idx < pack.seen - 1) showCard(pack.idx + 1, false);
  else if (pack.seen < pack.res.length){ pack.seen++; showCard(pack.seen - 1, true); }
});
document.getElementById("closeRevealBtn").addEventListener("click", () => {
  pack = null;
  document.getElementById("revealStage").hidden = true;
  document.getElementById("packStage").hidden = false;
});


(async function(){ await initPage(); await loadThemedTickets(); })();

/* ===== Tombola ===== */
// Métadonnées d'affichage (nom, couleurs) — mêmes que THEMES ci-dessus, réutilisées ici pour la
// tombola. Le calcul réel (qui gagne, quel thème ce tour, taille du "pot des autres joueurs")
// est fait côté serveur (026_raffle.sql).
let raffleState = null;

function themeMeta(id){ return THEMES.find(t => t.id === id) || { n: id, e: "?" }; }

async function refreshRaffle(){
  await supabaseClient.rpc("resolve_expired_raffles");
  const { data, error } = await supabaseClient.rpc("get_raffle_state");
  if (error){ console.error(error); return; }
  raffleState = data;
  renderRaffle();
}

function renderRaffle(){
  if (!raffleState) return;
  const t = themeMeta(raffleState.theme_id);
  const s = Math.max(0, Math.ceil(raffleState.ends_in_ms / 1000));
  document.getElementById("rfTimer").textContent = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  const pk = document.getElementById("rfPack");
  pk.textContent = t.e;
  pk.style.setProperty("--t1", t.c1);
  pk.style.setProperty("--t2", t.c2);
  document.getElementById("rfLot").textContent = "Lot : booster " + t.n;
  document.getElementById("rfDesc").textContent = "5 cartes " + t.n + ", mêmes chances de rareté et de brillante qu'un booster normal.";
  document.getElementById("rfTotal").textContent = raffleState.total;
  document.getElementById("rfMine").textContent = raffleState.mine;
  document.getElementById("rfChance").textContent = raffleState.total ? (raffleState.mine / raffleState.total * 100).toFixed(1).replace(".", ",") + " %" : "0 %";
  document.getElementById("rfStake").textContent = raffleState.mine ? "Ajouter" : "Miser";

  const last = raffleState.last;
  document.getElementById("rfLast").textContent = last
    ? "Dernière participation : " + (last.won ? "gagnée" : "perdue, mise remboursée") + ", booster " + themeMeta(last.theme_id).n + " (" + last.mine + " sur " + last.total + " pièces misées)."
    : "Mise le montant que tu veux et complète-la quand tu veux : plus ta part est grande, plus tu as de chances. Si tu perds, ta mise t'est rendue.";
}

document.getElementById("rfStake").addEventListener("click", async () => {
  const amount = parseInt(document.getElementById("rfAmt").value, 10);
  if (!(amount >= 1)){ toast("Entre une mise d'au moins 1 pièce."); return; }
  const { error } = await supabaseClient.rpc("stake_raffle", { p_amount: amount });
  if (error){ toast(error.message); return; }
  toast(amount + " pièces misées sur le booster " + themeMeta(raffleState.theme_id).n);
  await refreshHud();
  await refreshRaffle();
});

setInterval(refreshRaffle, 30000);
