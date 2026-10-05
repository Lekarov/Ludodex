// Fiche détail d'une carte : graphique de prix, onglets Infos/Marché.
// Extrait de ludodex.html sans changement de logique (étape 6 du plan de migration).
function chartSVG(h){
  if(h.length<2) return '<p class="note">Pas encore assez de ventes pour tracer une courbe.</p>';
  const W=300,H=120,pl=36,pr=8,pt=10,pb=20;
  const ts=h.map(x=>x.t),ps=h.map(x=>x.p);
  const t0=Math.min(...ts),t1=Math.max(...ts);
  let lo=Math.min(...ps),hi=Math.max(...ps); if(hi===lo){hi+=1;lo=Math.max(0,lo-1);}
  const X=t=>pl+(t1===t0?.5:(t-t0)/(t1-t0))*(W-pl-pr);
  const Y=p=>pt+(1-(p-lo)/(hi-lo))*(H-pt-pb);
  const pts=h.map(x=>`${X(x.t).toFixed(1)},${Y(x.p).toFixed(1)}`).join(" ");
  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Évolution du prix de vente">
    <line class="grid-l" x1="${pl}" x2="${W-pr}" y1="${Y(hi)}" y2="${Y(hi)}"/><line class="grid-l" x1="${pl}" x2="${W-pr}" y1="${Y(lo)}" y2="${Y(lo)}"/>
    <text x="${pl-5}" y="${Y(hi)+3}" text-anchor="end">${fmt(hi)}</text><text x="${pl-5}" y="${Y(lo)+3}" text-anchor="end">${fmt(lo)}</text>
    <polygon class="area" points="${X(t0)},${H-pb} ${pts} ${X(t1)},${H-pb}"/>
    <polyline class="line" points="${pts}"/>
    ${h.map(x=>`<circle class="${x.k==="e"?"pe":"pd"}" cx="${X(x.t).toFixed(1)}" cy="${Y(x.p).toFixed(1)}" r="2.8"/>`).join("")}
    <text x="${pl}" y="${H-4}">${dshort(t0)}</text><text x="${W-pr}" y="${H-4}" text-anchor="end">${dshort(t1)}</text>
  </svg>
  <p class="legend"><span><i style="background:var(--accent)"></i>Vente directe</span><span><i style="background:var(--gold)"></i>Enchère</span></p>`;
}
// Repli description multilingue : langue active -> anglais -> langue d'origine disponible -> rien.
// Les descriptions sont enrichies par la fixture dérivée IGDB/Steam ;
// cette fonction ne fabrique jamais de texte, elle retourne null si rien n'est disponible.
function pickDescription(g,lang){
  const d=g.description;
  if(!d||typeof d!=="object")return null;
  return d[lang]||d.en||Object.values(d).find(Boolean)||null;
}
function openDetail(id,sh){
  const g=GAMES[id],P=PLAT[g.p],R=RAR[g.r],n=state.owned[id]||0,s=state.shiny[id]||0;
  if(sh===undefined) sh=n>0&&n===s;
  sh=!!sh;
  const cnt=sh?s:n-s;
  const h=getHist(id,sh),m=mv(id,sh),dv=discardValue(g)*(sh?SHINY_MULT:1);
  const r30=h.filter(x=>x.t>Date.now()-30*864e5).map(x=>x.p);
  const last=h[h.length-1];
  const listed=state.listings.filter(l=>l.gid===id&&l.status==="active"&&!!l.sh===sh).length;
  const sub=[esc(P.n),g.y,g.d?esc(g.d):null].filter(Boolean).join(", ");
  const desc=pickDescription(g,"fr");
  $("dlgBody").innerHTML=`<div class="ddhead">
      <h3>${esc(g.t)}</h3>
      <span class="pill" style="--rc:${R.color}">${R.name}</span>${n===0?`<button class="btn sm wishbtn" type="button" data-wish="${id}" aria-pressed="${!!state.wish[id]}">${state.wish[id]?"♥ Recherchée":"♡ Je la cherche"}</button>`:""}
      <p class="dsub">${sub}</p>
      <p class="ddesc${desc?"":" unavailable"}">${desc?esc(desc):"Description indisponible."}</p>
      <div class="seg vseg">
        <button type="button" data-dtab="info" aria-pressed="${dtab==="info"}">Infos</button>
        <button type="button" data-dtab="market" aria-pressed="${dtab==="market"}">Marché</button>
      </div>
    </div>
    <div id="dtabInfo"${dtab==="info"?"":" hidden"}><div class="det">
    <div class="cw">${cardHTML(g,{shiny:sh})}</div>
    <div>
      <div class="owncount">
        <span>${n>0?`Tu en possèdes <b>${fmt(n)}</b>${listed?` (+${listed} en vente)`:""}`:"Pas encore obtenue"}</span>
        <div class="shinytog">
          <button type="button" data-act="detail" data-id="${id}" data-sh="0" aria-pressed="${!sh}" title="Version normale">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l3.5 6.5L22 12l-6.5 3.5L12 22l-3.5-6.5L2 12l6.5-3.5L12 2Z"></path></svg>
            ${n-s>0?`<span class="badge">${n-s}</span>`:""}
          </button>
          <button type="button" data-act="detail" data-id="${id}" data-sh="1" aria-pressed="${sh}" title="Version brillante">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v3M12 18v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M3 12h3M18 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"></path><circle cx="12" cy="12" r="3.2"></circle></svg>
            ${s>0?`<span class="badge">${s}</span>`:""}
          </button>
        </div>
      </div>
      <div class="statbox"><div class="atk"><b>${fmt(g.atk)}</b><span>ATK</span></div><div class="def"><b>${fmt(g.def)}</b><span>DEF</span></div></div>
      <dl class="meta">
        <dt>Note critique</dt><dd>${g.c} / 100</dd>
        <dt>Notoriété</dt><dd>${g.pop} / 100</dd>
        <dt>Durée de vie</dt><dd>environ ${g.h} h</dd>
      </dl>
      ${cnt>0?`<div class="actions start">
        <button class="btn primary" type="button" data-act="sell" data-id="${id}" data-sh="${sh?1:0}">Vendre${sh?" la brillante":""}</button>
        <button class="btn" type="button" data-act="discard" data-id="${id}" data-sh="${sh?1:0}">Défausser (+${fmt(dv)})</button>
        ${!sh?`<button class="btn sm" type="button" data-act="toggletrade" data-id="${id}" aria-pressed="${!!state.trade[id]}">${state.trade[id]?"🔄 À échanger":"Marquer à échanger"}</button>`:""}
      </div>`:""}
    </div></div></div>
    <div id="dtabMarket"${dtab==="market"?"":" hidden"}><div class="dfull">
      <div class="hstats">
        <div><span>Cote ${sh?"brillante":"normale"}</span><b>${fmt(m)}</b></div>
        <div><span>Dernière vente</span><b>${last?fmt(last.p):"-"}</b></div>
        <div><span>Plus bas 30 j</span><b>${r30.length?fmt(Math.min(...r30)):"-"}</b></div>
        <div><span>Plus haut 30 j</span><b>${r30.length?fmt(Math.max(...r30)):"-"}</b></div>
      </div>
      <div class="chart">${chartSVG(h)}</div>
      <ul class="sales">${h.slice(-6).reverse().map(x=>`<li><span>${dshort(x.t)}</span><span>${x.k==="e"?"Enchère":"Vente directe"}</span><b>${fmt(x.p)}</b></li>`).join("")}</ul>
    </div></div>`;
  save();
  showDlg();
}
$("dlgBody").addEventListener("click",e=>{
  const t=e.target.closest("[data-dtab]");if(!t)return;
  dtab=t.dataset.dtab;
  $("dlgBody").querySelectorAll("[data-dtab]").forEach(b=>b.setAttribute("aria-pressed",b.dataset.dtab===dtab));
  const infoP=$("dtabInfo"),mktP=$("dtabMarket");
  if(infoP)infoP.hidden=dtab!=="info";
  if(mktP)mktP.hidden=dtab!=="market";
});
function showDlg(){const d=$("dlg"); if(!d.open) d.showModal(); d.scrollTop=0;}
function closeDlg(){ $("dlg").close(); }
$("dlgClose").addEventListener("click",closeDlg);
$("dlg").addEventListener("click",e=>{if(e.target===$("dlg")) closeDlg();});
