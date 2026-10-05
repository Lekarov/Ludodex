// Sauvegarde localStorage : migration de schéma, état par défaut, lecture/écriture.
// Extrait de ludodex.html sans changement de logique (étape 4 du plan de migration).
function migrate(s){
  if(s.coins==null) s.coins=START_COINS;
  s.shiny=s.shiny||{}; s.shinyDrawn=s.shinyDrawn||0;
  s.ach=s.ach||{};
  s.rf=s.rf||{entries:{},themed:[],log:[]};
  s.bidLog=s.bidLog||[];
  s.wish=s.wish||{};
  s.gotAt=s.gotAt||{};
  s.set=Object.assign({sound:false,vol:0.6,spoil:false},s.set||{});
  if(!s.doneSets)s.doneSets=null;
  if(!s.st){
    const tx=s.tx||[],c=l=>tx.filter(x=>x.l===l);
    const sales=[...c("Vente directe"),...c("Enchère vendue")];
    s.st={bought:c("Achat direct").length,sold:sales.length,won:c("Enchère gagnée").length,earned:sales.reduce((a,x)=>a+x.a,0)};
  }
  s.listings=s.listings||[]; s.offers=s.offers||[]; s.hist=s.hist||{}; s.tx=s.tx||[];
  if(!s.simT) s.simT=Date.now(); if(!s.seq) s.seq=1;
  return s;
}
function fresh(){return migrate({v:1,isNew:true,owned:{},packs:MAX_PACKS,last:Date.now(),opened:0,golds:0,sinceGold:GOLD_EVERY-1,drawn:0,byR:RAR.map(()=>0),best:null});}
function load(){try{const s=JSON.parse(localStorage.getItem(KEY)); if(s&&s.v===1&&s.byR) return migrate(s);}catch(e){} return fresh();}
function persist(){try{localStorage.setItem(KEY,JSON.stringify(state));}catch(e){}}
function save(){persist();if(achReady)checkAch();}
let state=load();
