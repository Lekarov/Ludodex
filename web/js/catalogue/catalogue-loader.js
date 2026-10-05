// Chargeur et store du catalogue (fusion des 3 sources, rareté/ATK/DEF, cache navigateur).
// Extrait de ludodex.html sans changement de logique (étape 3 du plan de migration).
let PLAT_ORDER = Object.keys(PLAT);

/* ===== Catalogue Ludodex : chargement =====
   Les jeux ne sont plus recopiés dans ce fichier HTML. Ils sont chargés à
   l'exécution depuis trois fichiers JSON séparés (catalogue principal, volume 2,
   catalogue massif IGDB), fusionnés par clé stable (igdb:<id> / steam:<appid>).
   Priorité en cas de collision : catalogue principal > volume 2 > catalogue massif.
   La fixture de descriptions est fusionnée champ par champ pour enrichir les entrées.
   IMPORTANT : fetch() ne fonctionne pas sur une page ouverte en double-clic
   (protocole file://) à cause des restrictions CORS du navigateur. Il faut
   servir ce dossier via un petit serveur HTTP local, par exemple :
     python -m http.server 8080     (puis ouvrir http://localhost:8080/site/ludodex.html)
   ou toute autre méthode équivalente (l'hébergement LWS en HTTP normal fonctionne
   aussi tel quel, un simple dépôt FTP suffit une fois en ligne).
   c (note critique) et pop (popularité) utilisent les vraies données IGDB
   (selection.rating / rating_count) ou SteamSpy (positive_ratio / nb d'avis)
   quand elles existent dans la source ; sinon, comme h (durée en heures, jamais
   fournie par aucune source actuelle), un score PLACEHOLDER déterministe (hash de
   l'id catalogue, stable d'un chargement à l'autre) sert à faire tourner le moteur
   de rareté/ATK/DEF en attendant de vraies données. */
function hash32(str){let h=2166136261;for(let i=0;i<str.length;i++){h^=str.charCodeAt(i);h=Math.imul(h,16777619);}return h>>>0;}
function placeholderStats(id){
  const h1=hash32(id+"#c"),h2=hash32(id+"#p"),h3=hash32(id+"#h");
  return {c:45+(h1%50), pop:5+(h2%90), h:1+(h3%60)};
}
function computeStats(e){
  const ph=placeholderStats(e.id);
  let c=ph.c, pop=ph.pop;
  const sel=e.selection;
  if(sel&&typeof sel.rating==="number"){
    c=Math.max(1,Math.min(99,Math.round(sel.rating)));
    pop=Math.max(1,Math.min(99,Math.round(15+12*Math.log2((sel.rating_count||0)+1))));
  }else if(sel&&typeof sel.steamspy_positive_reviews==="number"){
    const pos=sel.steamspy_positive_reviews,neg=sel.steamspy_negative_reviews||0;
    const ratio=sel.steamspy_positive_ratio!=null?sel.steamspy_positive_ratio:pos/Math.max(1,pos+neg);
    c=Math.max(1,Math.min(99,Math.round(ratio*100)));
    pop=Math.max(1,Math.min(99,Math.round(15+9*Math.log2(pos+neg+1))));
  }
  return {c,pop,h:ph.h};
}
function pickPlatform(list){
  for(const [re,code,name,fam] of PLAT_PRIORITY){
    const hit=list.find(p=>re.test(p));
    if(hit) return {code,name,family:fam};
  }
  const raw=list[0]||"Inconnue";
  const code="p_"+raw.toLowerCase().replace(/[^a-z0-9]+/g,"").slice(0,16)||"autre";
  return {code,name:raw,family:"retro"};
}
let GAMES=[], BY_R=[];
let catalogueStatus={state:"loading",total:0,collisions:0,bySource:{}};
async function cachedFetch(url){
  if(!("caches" in window)) return fetch(url);
  const cache=await caches.open(CATALOGUE_CACHE);
  const hit=await cache.match(url);
  if(hit) return hit;
  const res=await fetch(url);
  if(res.ok) cache.put(url,res.clone());
  return res;
}
async function loadCatalogue(){
  // Les 3 fichiers sont chargés en parallèle (le catalogue massif fait ~16 Mo à lui
  // seul : les charger l'un après l'autre le faisait passer en dernier après une
  // attente inutile). Une fois chargés une première fois, ils sont servis depuis le
  // cache du navigateur (Cache Storage) : les rechargements suivants de la page ne
  // retéléchargent rien tant que CATALOGUE_CACHE n'est pas modifié.
  const fetchJson=async src=>{
    let res;
    try{ res=await cachedFetch(src.url); }
    catch(err){ throw new Error(`Impossible de charger ${src.label} (${src.url}) : ${err.message}. Le site doit être servi en HTTP, pas ouvert en double-clic (file://).`); }
    if(!res.ok) throw new Error(`${src.label} (${src.url}) a répondu ${res.status}.`);
    return {src,json:await res.json()};
  };
  const fetched=await Promise.all(CATALOGUE_SOURCES.map(fetchJson));
  const merged={};
  let collisions=0;
  fetched.forEach(({src,json})=>{
    const keys=Object.keys(json);
    catalogueStatus.bySource[src.label]=keys.length;
    keys.forEach(k=>{ if(merged[k]!==undefined) collisions++; merged[k]=json[k]; });
  });
  // La surcouche jaquettes (voir COVER_OVERRIDES_URL, écrite par LudodexCoverEditor) est
  // appliquée comme les descriptions : jamais une source de catalogue, jamais de nouvelle
  // fiche créée à partir du seul fichier de surcouche. Fichier absent ou vide toléré (aucune
  // correction faite encore) : ignoré silencieusement dans ce cas, log seulement en cas
  // d'erreur réelle (JSON invalide, etc.).
  try{
    const res=await cachedFetch(COVER_OVERRIDES_URL);
    if(res.ok){
      const overrides=await res.json();
      Object.keys(overrides).forEach(k=>{
        if(merged[k]===undefined) return;
        const o=overrides[k];
        if(o.coverUrl) merged[k].cover={...(merged[k].cover||{}),url:o.coverUrl,square_url:o.coverUrl};
        if(o.objectPosition) merged[k].coverPosition=o.objectPosition;
        if(o.zoom) merged[k].coverZoom=o.zoom;
      });
    }
  }catch(err){ console.warn("[Ludodex] surcouche jaquettes ignorée :",err.message); }
  // Les fichiers de description sont des SURCOUCHES (id -> {description}), pas des sources de
  // catalogue : on ne fusionne que le champ description, et seulement sur des jeux déjà connus —
  // jamais de nouvelle fiche créée à partir d'un fichier de description seul (ça donnerait des
  // cartes fantômes sans titre ni plateforme ni jaquette).
  let descOrphans=0;
  const descFetched=await Promise.allSettled(DESCRIPTION_SOURCES.map(fetchJson));
  descFetched.forEach((result,i)=>{
    const src=DESCRIPTION_SOURCES[i];
    if(result.status!=="fulfilled"){ console.warn("[Ludodex] descriptions ignorées :",src.label,result.reason&&result.reason.message); return; }
    const {json}=result.value;
    const keys=Object.keys(json);
    let applied=0;
    keys.forEach(k=>{
      if(merged[k]!==undefined && json[k]&&json[k].description){ merged[k].description=json[k].description; applied++; }
      else descOrphans++;
    });
    catalogueStatus.bySource[src.label]=`${applied}/${keys.length} appliquées`;
  });
  const entries=Object.values(merged);
  const rows=entries.map(e=>{
    const plats=e.platforms&&e.platforms.length?e.platforms:["Inconnue"];
    const {code,name,family}=pickPlatform(plats);
    if(!PLAT[code]) PLAT[code]={n:name,f:family};
    const {c,pop,h}=computeStats(e);
    const img=(e.cover&&(e.cover.url||e.cover.square_url))||null;
    return {t:e.title||"(titre inconnu)",p:code,y:e.year||0,d:e.developer||null,c,pop,h,img,imgPos:e.coverPosition||null,imgZoom:e.coverZoom||null,key:e.id,platforms:plats,description:e.description||null};
  });
  GAMES=rows.map((a,i)=>({id:i,t:a.t,p:a.p,y:a.y,d:a.d,c:a.c,pop:a.pop,h:a.h,img:a.img,imgPos:a.imgPos,imgZoom:a.imgZoom,key:a.key,platforms:a.platforms,description:a.description}));
  GAMES.forEach(g=>{ g.s=g.c*0.6+g.pop*0.4; g.r=0; });
  (function assignRarity(){
    const order=[...GAMES].sort((a,b)=>b.s-a.s);
    let idx=0;
    for(let r=RAR.length-1;r>=1;r--){
      const n=Math.max(1,Math.round(RAR[r].share*GAMES.length));
      for(let k=0;k<n&&idx<order.length;k++,idx++) order[idx].r=r;
    }
  })();
  GAMES.forEach(g=>{
    const m=RAR[g.r].mult;
    g.atk=Math.round(g.pop*20*m/10)*10;
    g.def=Math.round((100+Math.log10(g.h+1)*450)*m/10)*10;
  });
  BY_R=RAR.map((_,i)=>GAMES.filter(g=>g.r===i));
  PLAT_ORDER=Object.keys(PLAT);
  S_MIN=Math.min(...GAMES.map(g=>g.s)); S_MAX=Math.max(...GAMES.map(g=>g.s));
  // ACH/THEMES (succès, boosters thématiques) : pas repris ici, non utilisés par jeu.js.
  catalogueStatus={state:"ready",total:GAMES.length,collisions,descOrphans,withDescription:GAMES.filter(g=>g.description).length,bySource:catalogueStatus.bySource,noCover:GAMES.filter(g=>!g.img).length,platCodes:PLAT_ORDER.length};
  console.log("[Ludodex] catalogue chargé :",catalogueStatus);
  return catalogueStatus;
}
