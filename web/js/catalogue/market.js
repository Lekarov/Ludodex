// Marché : données, simulation des autres joueurs, notifications, achat/vente/enchères.
// Déplacé tel quel (logique + petite UI embarquée) — voir passation pour la limite connue.
// Extrait de ludodex.html sans changement de logique (étape 5 du plan de migration).
/* ===== Marché : données ===== */
const BOTS=["PixelNomade","RetroKaiser","Manette_Jo","Luna8bit","CartoucheMan","SaveStateSam","NeoGeoNina","Bitcrusher","DrLoot","ComboBreaker","Kiki16bit","LeMarchand"];
const botName=()=>BOTS[Math.floor(Math.random()*BOTS.length)];
const ME="moi";
let S_MIN=0, S_MAX=1; // recalculés dans loadCatalogue() une fois GAMES rempli
const ref=g=>Math.round(REF_BASE[g.r]*(0.8+0.4*(g.s-S_MIN)/(S_MAX-S_MIN)));
const discardValue=g=>Math.max(1,Math.round(ref(g)*DISCARD_RATE));
const netOf=p=>p-Math.ceil(p*FEE);
function mulberry32(a){return function(){a|=0;a=a+0x6D2B79F5|0;let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
const hkey=(id,sh)=>sh?id+"s":String(id);
function getHist(id,sh){
  const key=hkey(id,sh);
  let h=state.hist[key];
  if(!h){
    const g=GAMES[id],rnd=mulberry32(id*7919+13+(sh?101:0)),n=(sh?3:5)+Math.floor(rnd()*(sh?5:8)),now=Date.now();
    let v=ref(g)*(sh?SHINY_MULT:1)*(0.85+rnd()*0.3); h=[];
    for(let k=0;k<n;k++){
      const t=now-(30-(k+rnd())*(30/n))*864e5;
      v=Math.max(1,v*(0.9+rnd()*0.2));
      h.push({t:Math.round(t),p:Math.round(v),k:rnd()<.5?"d":"e"});
    }
    state.hist[key]=h;
  }
  return h;
}
function addSale(id,p,k,t,sh){const h=getHist(id,sh);h.push({t,p:Math.max(1,Math.round(p)),k});if(h.length>40)h.shift();}
function mv(id,sh){const ps=getHist(id,sh).slice(-8).map(x=>x.p).sort((a,b)=>a-b);if(!ps.length)return ref(GAMES[id])*(sh?SHINY_MULT:1);const m=ps.length>>1;return ps.length%2?ps[m]:Math.round((ps[m-1]+ps[m])/2);}
const topBid=o=>o.bids.length?o.bids[o.bids.length-1]:null;
const nextBid=o=>{const t=topBid(o);return t?t.a+Math.max(1,Math.round(t.a*0.07)):o.start;};
function randomCard(w){const b=BY_R[pickR(w)];return b[Math.floor(Math.random()*b.length)];}
function tx(t,label,gid,amount,sh){state.tx.unshift({t,l:label,g:gid,a:amount,sh:!!sh});if(state.tx.length>100)state.tx.length=100;}
function giveCard(id,sh,quiet){
  state.owned[id]=(state.owned[id]||0)+1;if(sh)state.shiny[id]=(state.shiny[id]||0)+1;
  state.gotAt[id]=Date.now();
  if(state.wish[id]){delete state.wish[id];if(!quiet)inbox("✨",`Souhait exaucé : ${GAMES[id].t}`);return true;}
  return false;
}
function takeCard(id,sh){
  const n=state.owned[id]||0,s=state.shiny[id]||0;
  if(sh?s<1:n-s<1)return false;
  state.owned[id]=n-1;if(!state.owned[id])delete state.owned[id];
  if(sh){state.shiny[id]=s-1;if(!state.shiny[id])delete state.shiny[id];}
  return true;
}
function newBotOffer(t){
  const g=randomCard(W_MARKET),sh=Math.random()<0.08,m=mv(g.id,sh),kind=Math.random()<.5?"fixed":"auction";
  const o={id:state.seq++,gid:g.id,sh,kind,seller:botName(),created:t,status:"active",bids:[]};
  if(kind==="fixed"){o.price=Math.max(1,Math.round(m*(0.9+Math.random()*0.4)));o.ends=t+24*36e5;}
  else{o.start=Math.max(1,Math.round(m*(0.5+Math.random()*0.3)));o.ends=t+(30+Math.floor(Math.random()*330))*6e4;}
  return o;
}

/* ===== Marché : simulation des autres joueurs =====
   Prototype local : les acheteurs et vendeurs sont simulés, minute par minute,
   y compris pendant que la page est fermée (rattrapage au retour, 3 jours max). */
const STEP=6e4;
function simulate(){
  const now=Date.now();let steps=Math.floor((now-state.simT)/STEP);
  if(steps<=0)return;
  const cap=3*1440; if(steps>cap){state.simT=now-cap*STEP;steps=cap;}
  const ev=[];
  for(let i=0;i<steps;i++){state.simT+=STEP;simStep(state.simT,ev);}
  state.offers=state.offers.filter(o=>o.status==="active"||now-(o.closedAt||0)<36e5);
  const closed=state.listings.filter(l=>l.status!=="active");
  if(closed.length>30){const keep=new Set(closed.sort((a,b)=>b.closedAt-a.closedAt).slice(0,30));state.listings=state.listings.filter(l=>l.status==="active"||keep.has(l));}
  save();
  renderTop();
  if(ev.length) notify(ev,steps>5);
}
function simStep(t,ev){
  if(Math.random()<0.12){const g=randomCard(W_MARKET),sh=Math.random()<0.1;addSale(g.id,mv(g.id,sh)*(0.85+Math.random()*0.3),Math.random()<.5?"d":"e",t,sh);}
  if(state.offers.filter(o=>o.status==="active").length<14&&Math.random()<0.25){
    const o=newBotOffer(t);state.offers.push(o);
    if(state.wish[o.gid])ev.push({type:"wish",gid:o.gid,a:o.kind==="fixed"?o.price:o.start,k:o.kind});
  }
  for(const o of state.offers){
    if(o.status!=="active")continue;
    const m=mv(o.gid,o.sh);
    if(o.kind==="fixed"){
      if(t>=o.ends){o.status="expired";o.closedAt=t;continue;}
      if(Math.random()<(o.price<=m*1.05?0.015:0.003)){o.status="sold";o.closedAt=t;o.buyer=botName();addSale(o.gid,o.price,"d",t,o.sh);}
    }else{
      if(t>=o.ends){closeBotAuction(o,t,ev);continue;}
      const nb=nextBid(o);
      if(Math.random()<0.05&&nb<=m*(0.9+Math.random()*0.5)){
        const prev=topBid(o);
        o.bids.push({who:botName(),a:nb,t});
        if(prev&&prev.who===ME){state.coins+=prev.a;ev.push({type:"outbid",gid:o.gid,a:prev.a});}
      }
    }
  }
  for(const L of state.listings){
    if(L.status!=="active")continue;
    const m=mv(L.gid,L.sh);
    if(L.kind==="fixed"){
      const r=L.price/m,p=r<=0.9?0.08:r<=1.05?0.03:r<=1.25?0.008:r<=1.6?0.0015:0;
      if(Math.random()<p){
        L.status="sold";L.closedAt=t;L.soldPrice=L.price;L.buyer=botName();
        const net=netOf(L.price);state.coins+=net;addSale(L.gid,L.price,"d",t,L.sh);
        tx(t,"Vente directe",L.gid,net,L.sh);state.st.sold++;state.st.earned+=net;ev.push({type:"sold",gid:L.gid,a:net});
      }
    }else{
      if(t>=L.ends){closeMyAuction(L,t,ev);continue;}
      const nb=nextBid(L);
      if(Math.random()<0.06&&nb<=m*(0.85+Math.random()*0.6)) L.bids.push({who:botName(),a:nb,t});
    }
  }
}
function closeBotAuction(o,t,ev){
  o.closedAt=t;const top=topBid(o);
  const myBids=o.bids.filter(b=>b.who===ME);
  if(myBids.length){
    state.bidLog.unshift({gid:o.gid,sh:!!o.sh,t,my:Math.max(...myBids.map(b=>b.a)),final:top.a,won:top.who===ME});
    if(state.bidLog.length>20)state.bidLog.length=20;
  }
  if(!top){o.status="expired";return;}
  o.status="sold";o.buyer=top.who;addSale(o.gid,top.a,"e",t,o.sh);
  if(top.who===ME){giveCard(o.gid,o.sh);state.st.won++;tx(t,"Enchère gagnée",o.gid,-top.a,o.sh);ev.push({type:"won",gid:o.gid,a:top.a});}
}
function closeMyAuction(L,t,ev){
  L.closedAt=t;const top=topBid(L);
  if(!top){L.status="expired";giveCard(L.gid,L.sh);ev.push({type:"unsold",gid:L.gid});return;}
  L.status="sold";L.soldPrice=top.a;L.buyer=top.who;
  const net=netOf(top.a);state.coins+=net;addSale(L.gid,top.a,"e",t,L.sh);
  tx(t,"Enchère vendue",L.gid,net,L.sh);state.st.sold++;state.st.earned+=net;ev.push({type:"sold",gid:L.gid,a:net});
}

/* ===== Notifications ===== */
function toast(msg){
  const el=document.createElement("div");el.className="toast";el.textContent=msg;
  $("toasts").replaceChildren(el);setTimeout(()=>el.remove(),2400);
}
/* Boîte de notifications : les événements arrivent ici, sans rien afficher à l'écran */
const INBOX_MAX=40;
function inbox(ic,msg){
  if(!Array.isArray(state.inbox))state.inbox=[];
  state.inbox.unshift({t:Date.now(),ic,m:msg,r:false});
  if(state.inbox.length>INBOX_MAX)state.inbox.length=INBOX_MAX;
  persist();renderBell();
}
function renderBell(){
  const n=(state.inbox||[]).filter(x=>!x.r).length,b=$("nbub");
  b.hidden=!n;b.textContent=n>9?"9+":n;
  $("bellBtn").setAttribute("aria-label",n?`Notifications, ${n} non lue${n>1?"s":""}`:"Notifications");
}
function openInbox(){
  const L=state.inbox||[];
  $("dlgBody").innerHTML=`<div class="gsec"><h3>Notifications</h3>
    ${L.length?`<ul class="nlist">${L.map(x=>`<li class="${x.r?"":"unread"}"><span class="ni" aria-hidden="true">${x.ic}</span><span>${esc(x.m)}<small>${ago(x.t)}</small></span></li>`).join("")}</ul>
    <div class="actions" style="margin-top:.8rem"><button class="btn sm" type="button" data-nclear="1">Tout effacer</button></div>`
    :`<p class="nempty">Rien de nouveau pour l'instant.</p>`}</div>`;
  showDlg();
  L.forEach(x=>x.r=true);persist();renderBell();
}
$("bellBtn").addEventListener("click",openInbox);
$("dlgBody").addEventListener("click",e=>{if(e.target.closest("[data-nclear]")){state.inbox=[];persist();renderBell();openInbox();}});
function notify(ev,away){
  const T=id=>GAMES[id].t;
  if(ev.some(e=>e.type==="won"))sfx.fanfare();else if(ev.some(e=>e.type==="sold"))sfx.coin();
  for(const e of ev){
    if(e.type==="sold")inbox("💰",`Vendu : ${T(e.gid)} (+${fmt(e.a)} pièces)`);
    if(e.type==="won")inbox("🔨",`Enchère gagnée : ${T(e.gid)}`);
    if(e.type==="outbid")inbox("↩️",`Surenchéri sur ${T(e.gid)}, ${fmt(e.a)} pièces rendues`);
    if(e.type==="wish")inbox("♥",`${T(e.gid)} est en vente : ${fmt(e.a)} pièces${e.k==="fixed"?"":" (enchère)"}`);
    if(e.type==="unsold")inbox("📦",`Invendu : ${T(e.gid)} revient dans ta collection`);
  }
}

/* ===== Marché : affichage ===== */
let mkTab="buy";
function left(ms){if(ms<=0)return "terminée";const m=Math.ceil(ms/6e4);if(m<60)return `${m} min`;const h=Math.floor(m/60),r=m%60;if(h<24)return r?`${h} h ${r}`:`${h} h`;return `${Math.floor(h/24)} j`;}
function ago(t){const m=Math.floor((Date.now()-t)/6e4);if(m<1)return "à l'instant";if(m<60)return `il y a ${m} min`;const h=Math.floor(m/60);if(h<24)return `il y a ${h} h`;return `il y a ${Math.floor(h/24)} j`;}
function dshort(t){return new Date(t).toLocaleDateString("fr-FR",{day:"numeric",month:"short"});}
function thumbHTML(g,sh){return `<span class="thumb${sh?" holo-t":""}" style="--pc:${FAM[PLAT[g.p].f]};--rc:${RAR[g.r].color}" aria-hidden="true">${esc(initials(g.t))}</span>`;}
const coinHTML='<span class="coin" aria-hidden="true"></span>';
function rowHead(g,sh){return `${thumbHTML(g,sh)}<div><button class="mt" type="button" data-act="detail" data-id="${g.id}" data-sh="${sh?1:0}">${state.wish[g.id]?'<span class="wishmark" aria-label="Dans ta liste de souhaits">♥ </span>':""}${esc(g.t)}${sh?'<span class="shtag">✦ Brillante</span>':""}</button>
  <div class="ms">${esc(PLAT[g.p].n)}, ${g.y}, <span class="rp" style="--rc:${RAR[g.r].color}">${RAR[g.r].name}</span></div>`;}
function renderMarket(){
  $("coins2").textContent=fmt(state.coins);
  document.querySelectorAll("#mkSeg button").forEach(b=>b.setAttribute("aria-pressed",b.dataset.mk===mkTab));
  ["buy","mine","bids","hist"].forEach(k=>$("mk-"+k).hidden=k!==mkTab);
  if(mkTab==="buy")renderBuy();
  if(mkTab==="mine")renderMine();
  if(mkTab==="bids")renderBids();
  if(mkTab==="hist")renderHist();
}
function renderBuy(){
  const ft=$("mkType").value,fr=$("mkRar").value,q=$("mkQ").value.trim().toLowerCase(),now=Date.now();
  const list=state.offers.filter(o=>o.status==="active"&&(!ft||(ft==="wish"?state.wish[o.gid]:o.kind===ft))&&(fr===""||GAMES[o.gid].r===+fr)&&(!q||GAMES[o.gid].t.toLowerCase().includes(q)))
    .sort((a,b)=>(!!state.wish[b.gid]-!!state.wish[a.gid])||b.created-a.created);
  $("mkBuyList").innerHTML=list.length?list.map(o=>{
    const g=GAMES[o.gid],m=mv(o.gid,o.sh),top=topBid(o),mine=top&&top.who===ME;
    const price=o.kind==="fixed"?o.price:(top?top.a:o.start);
    const info=o.kind==="fixed"?"Prix fixe":`${o.bids.length?`${o.bids.length} offre${o.bids.length>1?"s":""}`:"Mise de départ"}, fin dans ${left(o.ends-now)}`;
    const btn=o.kind==="fixed"
      ?`<button class="btn primary sm" type="button" data-act="buy" data-o="${o.id}">Acheter</button>`
      :mine?`<span class="lead ms">Tu es en tête</span>`:`<button class="btn primary sm" type="button" data-act="bid" data-o="${o.id}">Enchérir</button>`;
    return `<li class="mrow">${rowHead(g,o.sh)}<div class="ms">${info}</div><div class="ms">Vendeur : ${esc(o.seller)}, cote ${fmt(m)}</div></div>
      <div class="mside"><span class="mp">${fmt(price)}${coinHTML}</span>${btn}</div></li>`;
  }).join(""):`<li class="mempty">Aucune offre ne correspond. De nouvelles annonces arrivent régulièrement.</li>`;
}
function renderMine(){
  const now=Date.now();
  const act=state.listings.filter(l=>l.status==="active").sort((a,b)=>b.created-a.created);
  const done=state.listings.filter(l=>l.status!=="active").sort((a,b)=>b.closedAt-a.closedAt).slice(0,15);
  let html=`<h2 class="msub">En vente</h2><ul class="mlist">`;
  html+=act.length?act.map(L=>{
    const g=GAMES[L.gid],top=topBid(L);
    const price=L.kind==="fixed"?L.price:(top?top.a:L.start);
    const info=L.kind==="fixed"?`Vente directe, cote ${fmt(mv(L.gid,L.sh))}`:`Enchère, ${L.bids.length?`${L.bids.length} offre${L.bids.length>1?"s":""}`:"aucune offre"}, fin dans ${left(L.ends-now)}`;
    const canCancel=L.kind==="fixed"||!L.bids.length;
    return `<li class="mrow">${rowHead(g,L.sh)}<div class="ms">${info}</div></div>
      <div class="mside"><span class="mp">${fmt(price)}${coinHTML}</span>${canCancel?`<button class="btn sm" type="button" data-act="cancel" data-l="${L.id}">Retirer</button>`:`<span class="ms">Offres en cours</span>`}</div></li>`;
  }).join(""):`<li class="mempty">Rien en vente. Ouvre une carte de ta collection et touche « Vendre ».</li>`;
  html+=`</ul>`;
  if(done.length){
    html+=`<h2 class="msub">Terminées</h2><ul class="mlist">`+done.map(L=>{
      const g=GAMES[L.gid];
      const st=L.status==="sold"?`<span class="pos">Vendu +${fmt(netOf(L.soldPrice))}</span>`:L.status==="expired"?"Invendu, carte rendue":"Retiré";
      return `<li class="mrow">${rowHead(g,L.sh)}<div class="ms">${L.kind==="fixed"?"Vente directe":"Enchère"}, ${ago(L.closedAt)}</div></div><div class="mside ms">${st}</div></li>`;
    }).join("")+`</ul>`;
  }
  $("mk-mine").innerHTML=html;
}
function renderBids(){
  const now=Date.now();
  const act=state.offers.filter(o=>o.status==="active"&&o.kind==="auction"&&o.bids.some(b=>b.who===ME)).sort((a,b)=>a.ends-b.ends);
  let html=`<h2 class="msub">En cours</h2><ul class="mlist">`;
  html+=act.length?act.map(o=>{
    const g=GAMES[o.gid],top=topBid(o),lead=top.who===ME;
    const my=Math.max(...o.bids.filter(b=>b.who===ME).map(b=>b.a));
    return `<li class="mrow">${rowHead(g,o.sh)}<div class="ms">${lead?`<span class="lead">Tu es en tête</span>`:`<span class="neg">Dépassé</span> (ta mise : ${fmt(my)})`}, fin dans ${left(o.ends-now)}</div></div>
      <div class="mside"><span class="mp">${fmt(top.a)}${coinHTML}</span>${lead?`<span class="ms">Pièces bloquées</span>`:`<button class="btn primary sm" type="button" data-act="bid" data-o="${o.id}">Surenchérir</button>`}</div></li>`;
  }).join(""):`<li class="mempty">Aucune enchère en cours. Trouve une carte dans « Acheter » et touche « Enchérir ».</li>`;
  html+=`</ul>`;
  if(state.bidLog.length){
    html+=`<h2 class="msub">Terminées</h2><ul class="mlist">`+state.bidLog.map(x=>{
      const g=GAMES[x.gid];
      return `<li class="mrow">${rowHead(g,x.sh)}<div class="ms">Ta meilleure offre : ${fmt(x.my)}, ${ago(x.t)}</div></div>
        <div class="mside ms">${x.won?`<span class="pos">Gagnée</span><span>${fmt(x.final)} pièces</span>`:`<span>Perdue</span><span>Adjugée ${fmt(x.final)}</span>`}</div></li>`;
    }).join("")+`</ul>`;
  }
  $("mk-bids").innerHTML=html;
}
function renderHist(){
  $("mk-hist").innerHTML=state.tx.length?`<ul class="mlist">`+state.tx.slice(0,60).map(x=>{
    const g=GAMES[x.g];
    const head=g?rowHead(g,x.sh):`<span class="thumb ach-t" aria-hidden="true">★</span><div><div class="mt">${esc(x.n||"Succès")}</div>`;
    return `<li class="mrow">${head}<div class="ms">${esc(x.l)}, ${ago(x.t)}</div></div>
      <div class="mside"><span class="mp ${x.a>=0?"pos":"neg"}">${x.a>=0?"+":"−"}${fmt(Math.abs(x.a))}${coinHTML}</span></div></li>`;
  }).join("")+`</ul>`:`<p class="mempty">Aucune transaction pour l'instant. Tes achats, ventes, défausses et récompenses de succès apparaîtront ici.</p>`;
}

/* ===== Marché : actions ===== */
function openSell(id,mode,sh){
  const g=GAMES[id],m=mv(id,sh),def=mode==="fixed"?m:Math.max(1,Math.round(m*0.7));
  $("dlgBody").innerHTML=`<div class="form">
    <h3 class="dtitle">Vendre ${esc(g.t)}${sh?'<span class="shtag">✦ Brillante</span>':""}</h3>
    <p class="dsub">Cote actuelle : ${fmt(m)} pièces. Exemplaires ${sh?"brillants":"normaux"} : ${sh?(state.shiny[id]||0):(state.owned[id]||0)-(state.shiny[id]||0)}.</p>
    <div class="seg">
      <button type="button" data-act="mode" data-id="${id}" data-sh="${sh?1:0}" data-m="fixed" aria-pressed="${mode==="fixed"}">Vente directe</button>
      <button type="button" data-act="mode" data-id="${id}" data-sh="${sh?1:0}" data-m="auction" aria-pressed="${mode==="auction"}">Enchère</button>
    </div>
    <label>${mode==="fixed"?"Prix de vente":"Prix de départ"}<input id="sellPrice" type="number" inputmode="numeric" min="1" step="1" value="${def}"></label>
    ${mode==="auction"?`<label>Durée<select id="sellDur"><option value="30">30 min</option><option value="120">2 h</option><option value="720" selected>12 h</option><option value="1440">24 h</option></select></label>`:""}
    <p class="note" id="sellNet" data-m="${mode}" data-ref="${m}"></p>
    <div class="actions">
      <button class="btn" type="button" data-act="detail" data-id="${id}" data-sh="${sh?1:0}">Retour</button>
      <button class="btn primary" type="button" data-act="sellOk" data-id="${id}" data-sh="${sh?1:0}" data-m="${mode}">Mettre en vente</button>
    </div></div>`;
  updSellNote();showDlg();
}
function updSellNote(){
  const n=$("sellNet");if(!n)return;
  const v=parseInt($("sellPrice").value,10),m=+n.dataset.ref;
  if(!(v>=1)){n.innerHTML=`<span class="err">Entre un prix d'au moins 1 pièce.</span>`;return;}
  n.textContent=n.dataset.m==="fixed"
    ?`Tu recevras ${fmt(netOf(v))} pièces.${v>m*1.25?" Au-dessus de la cote : la vente risque de prendre du temps.":v<m*0.9?" Sous la cote : la vente devrait être rapide.":""}`
    :`Tu recevras le prix final de l'enchère. Sans offre à la fin, la carte revient dans ta collection.`;
}
function sellOk(id,mode,sh){
  const v=parseInt($("sellPrice").value,10);
  if(!(v>=1)){updSellNote();return;}
  if(!takeCard(id,sh)){toast("Tu n'as plus d'exemplaire de cette carte.");closeDlg();return;}
  const now=Date.now(),L={id:state.seq++,gid:id,sh:!!sh,kind:mode,created:now,status:"active",bids:[]};
  if(mode==="fixed")L.price=v;else{L.start=v;L.ends=now+parseInt($("sellDur").value,10)*6e4;}
  state.listings.push(L);save();closeDlg();
  toast(`${mode==="fixed"?"Mis en vente":"Enchère lancée"} : ${GAMES[id].t}`);
  refreshViews();
}
function discard(btn,id,sh){
  const g=GAMES[id],dv=discardValue(g)*(sh?SHINY_MULT:1);
  if(btn.dataset.armed!=="1"){btn.dataset.armed="1";btn.textContent=`Confirmer (+${fmt(dv)})`;return;}
  if(!takeCard(id,sh))return;
  state.coins+=dv;tx(Date.now(),"Défausse",id,dv,sh);save();sfx.coin();
  toast(`Défaussé : ${g.t} (+${fmt(dv)} pièces)`);
  if(state.owned[id])openDetail(id,sh&&state.shiny[id]>0);else closeDlg();
  refreshViews();
}
function openBuy(oid){
  const o=state.offers.find(x=>x.id===oid);if(!o||o.status!=="active"){toast("Cette offre n'est plus disponible.");refreshViews();return;}
  const g=GAMES[o.gid],ok=state.coins>=o.price;
  $("dlgBody").innerHTML=`<div class="form">
    <h3 class="dtitle">Acheter ${esc(g.t)}${o.sh?'<span class="shtag">✦ Brillante</span>':""}</h3>
    <p class="dsub">Vendu par ${esc(o.seller)} pour ${fmt(o.price)} pièces (cote ${fmt(mv(o.gid,o.sh))}).</p>
    <p class="${ok?"note":"err"}">${ok?`Solde après achat : ${fmt(state.coins-o.price)} pièces.`:`Il te manque ${fmt(o.price-state.coins)} pièces.`}</p>
    <div class="actions"><button class="btn" type="button" data-act="close">Annuler</button>
    <button class="btn primary" type="button" data-act="buyOk" data-o="${o.id}" ${ok?"":"disabled"}>Acheter</button></div></div>`;
  showDlg();
}
function buyOk(oid){
  const o=state.offers.find(x=>x.id===oid),now=Date.now();
  if(!o||o.status!=="active"){toast("Cette offre n'est plus disponible.");closeDlg();refreshViews();return;}
  if(state.coins<o.price)return;
  state.coins-=o.price;giveCard(o.gid,o.sh);state.st.bought++;o.status="sold";o.closedAt=now;o.buyer=ME;
  addSale(o.gid,o.price,"d",now,o.sh);tx(now,"Achat direct",o.gid,-o.price,o.sh);save();closeDlg();
  toast(`Acheté : ${GAMES[o.gid].t}`);sfx.coin();refreshViews();
}
function openBid(oid){
  const o=state.offers.find(x=>x.id===oid),now=Date.now();
  if(!o||o.status!=="active"||now>=o.ends){toast("Cette enchère est terminée.");refreshViews();return;}
  const g=GAMES[o.gid],top=topBid(o),nb=nextBid(o);
  $("dlgBody").innerHTML=`<div class="form">
    <h3 class="dtitle">Enchérir sur ${esc(g.t)}${o.sh?'<span class="shtag">✦ Brillante</span>':""}</h3>
    <p class="dsub">${top?`Meilleure offre : ${fmt(top.a)} pièces (${esc(top.who===ME?"toi":top.who)})`:`Mise de départ : ${fmt(o.start)} pièces`}. Fin dans ${left(o.ends-now)}. Cote ${fmt(mv(o.gid,o.sh))}.</p>
    <label>Ton offre (minimum ${fmt(nb)})<input id="bidAmt" type="number" inputmode="numeric" min="${nb}" step="1" value="${nb}"></label>
    <p class="note" id="bidNote">Les pièces sont bloquées tant que tu es en tête, et rendues si quelqu'un te dépasse. Solde : ${fmt(state.coins)} pièces.</p>
    <div class="actions"><button class="btn" type="button" data-act="close">Annuler</button>
    <button class="btn primary" type="button" data-act="bidOk" data-o="${o.id}">Enchérir</button></div></div>`;
  showDlg();
}
function bidOk(oid){
  const o=state.offers.find(x=>x.id===oid),now=Date.now();
  if(!o||o.status!=="active"||now>=o.ends){toast("Cette enchère est terminée.");closeDlg();refreshViews();return;}
  const v=parseInt($("bidAmt").value,10),nb=nextBid(o);
  if(!(v>=nb)){$("bidNote").innerHTML=`<span class="err">L'offre doit être d'au moins ${fmt(nb)} pièces.</span>`;return;}
  if(v>state.coins){$("bidNote").innerHTML=`<span class="err">Solde insuffisant (${fmt(state.coins)} pièces).</span>`;return;}
  const prev=topBid(o);
  if(prev&&prev.who===ME)state.coins+=prev.a;
  state.coins-=v;o.bids.push({who:ME,a:v,t:now});save();closeDlg();
  toast(`Offre placée : ${fmt(v)} pièces sur ${GAMES[o.gid].t}`);refreshViews();
}
function cancelListing(lid){
  const L=state.listings.find(x=>x.id===lid);
  if(!L||L.status!=="active"||(L.kind==="auction"&&L.bids.length))return;
  L.status="cancelled";L.closedAt=Date.now();giveCard(L.gid,L.sh);save();
  toast(`Retiré de la vente : ${GAMES[L.gid].t}`);refreshViews();
}
function refreshViews(){
  renderTop();
  if($("view-market").classList.contains("active"))renderMarket();
  if($("view-coll").classList.contains("active"))renderColl();
  if($("view-stats").classList.contains("active"))renderStats();
  if($("view-amis").classList.contains("active"))renderAmis();
}
function onAct(e){
  const b=e.target.closest("[data-act]");if(!b)return;
  const a=b.dataset.act,id=+b.dataset.id,o=+b.dataset.o,sh=b.dataset.sh==="1";
  if(a==="detail")openDetail(id,b.dataset.sh===undefined?undefined:sh);
  else if(a==="sell")openSell(id,"fixed",sh);
  else if(a==="mode")openSell(id,b.dataset.m,sh);
  else if(a==="sellOk")sellOk(id,b.dataset.m,sh);
  else if(a==="discard")discard(b,id,sh);
  else if(a==="buy")openBuy(o);
  else if(a==="buyOk")buyOk(o);
  else if(a==="bid")openBid(o);
  else if(a==="bidOk")bidOk(o);
  else if(a==="cancel")cancelListing(+b.dataset.l);
  else if(a==="close")closeDlg();
}
$("dlgBody").addEventListener("click",onAct);
$("view-market").addEventListener("click",onAct);
$("dlgBody").addEventListener("input",e=>{if(e.target.id==="sellPrice")updSellNote();});
$("mkSeg").addEventListener("click",e=>{const b=e.target.closest("[data-mk]");if(b){mkTab=b.dataset.mk;renderMarket();}});
["mkType","mkRar"].forEach(i=>$(i).addEventListener("change",renderBuy));
$("mkQ").addEventListener("input",renderBuy);
$("walletBtn").addEventListener("click",()=>goTab("market"));
