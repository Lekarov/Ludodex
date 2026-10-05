// Rendu des cartes (possédée / fantôme / manquante), liste de souhaits, reflet holo au pointeur.
// Extrait de ludodex.html sans changement de logique (étape 6 du plan de migration).
// Icônes ATK/DEF reprises de js/render.js (bibliothèque open source Lucide, licence ISC) —
// dupliquées ici plutôt qu'importées : ce moteur hors ligne ne charge pas render.js.
const ICON_SWORDS = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="14.5 17.5 3 6 3 3 6 3 17.5 14.5"></polyline><line x1="13" x2="19" y1="19" y2="13"></line><line x1="16" x2="20" y1="16" y2="20"></line><line x1="19" x2="21" y1="21" y2="19"></line><polyline points="14.5 6.5 18 3 21 3 21 6 17.5 9.5"></polyline><line x1="5" x2="9" y1="14" y2="18"></line><line x1="7" x2="4" y1="17" y2="20"></line><line x1="3" x2="5" y1="19" y2="21"></line></svg>';
const ICON_SHIELD = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"></path></svg>';
// Fonds texturés du bandeau du bas, dupliqués de js/render.js (ce moteur hors ligne ne le charge pas).
const CARD_BG = [
  "assets/card-bg-commune-v1.png",
  "assets/card-bg-peu-commune-v1.png",
  "assets/card-bg-rare-v1.png",
  "assets/card-bg-epique-v1.png",
  "assets/card-bg-legendaire-v1.png",
  "assets/card-bg-mythique-v1.png",
];
function cardHTML(g,o={}){
  const P=PLAT[g.p],R=RAR[g.r];
  const rarityLetter=["C","U","R","E","L","M"][g.r]||"C";
  const imageStyle=(g.imgPos||g.imgZoom)?` style="${g.imgPos?`object-position:${esc(g.imgPos)};`:''}${g.imgZoom&&g.imgZoom!==1?`transform:scale(${g.imgZoom});transform-origin:${esc(g.imgPos||"50% 50%")};`:''}"`:'';
  const photo=g.img
    ?`<img src="${esc(g.img)}" alt="" loading="lazy" onerror="this.remove()"${imageStyle}>`
    :`<span>${esc(initials(g.t))}</span>`;
  return `<div class="card r${g.r}${o.shiny?" holo":""}" style="--pc:${FAM[P.f]};--rc:${R.color}">
    <div class="cc-photo">${photo}</div>
    <b class="cc-badge" role="img" aria-label="${esc(R.name)}" title="${esc(R.name)}">${rarityLetter}</b>
    ${o.count>1?`<b class="cnt">×${o.count}</b>`:''}${o.sc?`<b class="scn">✦ ${o.sc}</b>`:''}
    <div class="cc-body" style="background-image:url(${CARD_BG[g.r]||CARD_BG[0]})">
      <h4 class="cc-title">${esc(g.t)}</h4>
      <p class="cc-sub">${esc(g.description||P.n)}</p>
      <div class="cc-stats"><span class="cc-atk">${ICON_SWORDS}${fmt(g.atk)}</span>
      <span class="cc-def">${ICON_SHIELD}${fmt(g.def)}</span></div>
    </div></div>`;
}
function ghostHTML(g){
  const P=PLAT[g.p],R=RAR[g.r];
  return `<div class="card ghost" style="--pc:${FAM[P.f]};--rc:${R.color}">
    <div class="cc-photo"><span>?</span></div>
    <b class="cc-badge" title="${esc(R.name)}">${esc(R.name[0])}</b>
    <div class="cc-body" style="background-image:url(${CARD_BG[g.r]||CARD_BG[0]})">
      <h4 class="cc-title">Carte inconnue</h4>
      <div class="cc-stats"><span class="cc-atk">${ICON_SWORDS}—</span>
      <span class="cc-def">${ICON_SHIELD}—</span></div>
    </div></div>`;
}


/* ===== Liste de souhaits ===== */
function toggleWish(id){
  if(state.owned[id])return;
  if(state.wish[id])delete state.wish[id];else state.wish[id]=true;
  persist();
  if($("dlg").open&&$("dlgBody").querySelector(".det"))openDetail(id,false);
  refreshViews();
}
document.addEventListener("click",e=>{
  const b=e.target.closest("[data-wish]");if(!b)return;
  e.stopPropagation();toggleWish(+b.dataset.wish);
},true);
function missingHTML(g,label){
  const w=!!state.wish[g.id];
  const inner=state.set.spoil
    ?`<button class="cw slot missing" type="button" data-id="${g.id}" aria-label="${esc(g.t)}, pas encore obtenue">${cardHTML(g)}</button>`
    :`<div class="cw slot" aria-label="${label}">${ghostHTML(g)}</div>`;
  return `<div class="mslot">${inner}<button class="heart" type="button" data-wish="${g.id}" aria-pressed="${w}" aria-label="${w?"Retirer de":"Ajouter à"} ma liste de souhaits">${w?"♥":"♡"}</button></div>`;
}
/* ===== Reflet des cartes brillantes ===== */
document.addEventListener("pointermove",e=>{
  const cw=e.target.closest&&e.target.closest(".cw");
  if(!cw||!cw.querySelector(".holo"))return;
  const r=cw.getBoundingClientRect();
  cw.classList.add("tracking");
  cw.style.setProperty("--hx",((e.clientX-r.left)/r.width*100).toFixed(1)+"%");
  cw.style.setProperty("--hy",((e.clientY-r.top)/r.height*100).toFixed(1)+"%");
},{passive:true});
