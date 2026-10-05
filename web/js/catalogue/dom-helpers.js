// Petits utilitaires transverses (sélection DOM, échappement HTML, formatage) utilisés par
// tous les autres scripts, y compris ceux qui enregistrent des écouteurs d'événements dès leur
// chargement (avant que le script principal ne s'exécute) — doit donc être chargé en premier.
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmt=n=>n.toLocaleString("fr-FR");
const STOP=new Set(["the","of","la","le","les","de","du","des","and","et","l","d"]);
function initials(t){
  const w=t.replace(/[^\p{L}\p{N}\s]/gu," ").split(/\s+/).filter(x=>x&&!STOP.has(x.toLowerCase()));
  return w.slice(0,2).map(x=>x[0]).join("").toUpperCase();
}
function ownedCount(){return Object.keys(state.owned).length;}
