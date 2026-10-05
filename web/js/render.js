// Rendu de carte pour Ludodex Online — variante allégée de site/js/ui/card-render.js : prend un
// objet plat venant directement de card_catalogue (titre, plateforme, couleurs déjà résolues),
// pas besoin de charger GAMES/RAR/PLAT/FAM (tout le catalogue) côté client pour ça.
// Dépend seulement de dom-helpers.js (esc, fmt, initials).
// Icônes ATK/DEF (croix d'épées / bouclier), reprises telles quelles de la bibliothèque
// open source Lucide (licence ISC) — pas un asset propriétaire.
const ICON_SWORDS = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="14.5 17.5 3 6 3 3 6 3 17.5 14.5"></polyline><line x1="13" x2="19" y1="19" y2="13"></line><line x1="16" x2="20" y1="16" y2="20"></line><line x1="19" x2="21" y1="21" y2="19"></line><polyline points="14.5 6.5 18 3 21 3 21 6 17.5 9.5"></polyline><line x1="5" x2="9" y1="14" y2="18"></line><line x1="7" x2="4" y1="17" y2="20"></line><line x1="3" x2="5" y1="19" y2="21"></line></svg>';
const ICON_SHIELD = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"></path></svg>';
// Icône "œil" (voir un profil), même bibliothèque Lucide (ISC) que les autres icônes de ce fichier.
const ICON_EYE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"></path><circle cx="12" cy="12" r="3"></circle></svg>';

// Fonds texturés (marbrure/foil) du bandeau du bas, un par palier de rareté — générés par
// ChatGPT/gpt-image-2 (voir web/assets/card-bg-*-v1.png), indexés comme RARITY_ORDER (shared.js).
const CARD_BG = [
  "assets/card-bg-commune-v1.png",
  "assets/card-bg-peu-commune-v1.png",
  "assets/card-bg-rare-v1.png",
  "assets/card-bg-epique-v1.png",
  "assets/card-bg-legendaire-v1.png",
  "assets/card-bg-mythique-v1.png",
];

// Description affichée sur la carte elle-même (façon WikiMasters : la carte porte son propre
// résumé, pas seulement la plateforme) — même repli que bioHTML côté fiche détail (detail.js),
// mais texte brut ici puisque le clamp CSS gère la coupure (pas de mention "indisponible" sur la
// mini-carte, seulement dans la fiche détail).
function cardSubText(g){
  return g.description_fr || g.description_en || g.genres || g.platform_name || "";
}

// Badge de grade affiché sur le profil (profiles.role, voir 001/057/058_*.sql) — purement
// visuel/déclaratif, un style propre par rang ; le rôle par défaut "player" n'affiche rien.
const ROLE_BADGES = {
  fondateur: { label: "Fondateur", icon: "👑" },
  admin: { label: "Admin", icon: "🛡" },
  moderator: { label: "Modérateur", icon: "🛡" },
  vip: { label: "VIP", icon: "✨" },
};
function roleBadgeHTML(role){
  const b = ROLE_BADGES[role];
  return b ? '<span class="rolebadge rb-' + role + '">' + b.icon + ' ' + b.label + '</span>' : "";
}

// Cadrage par carte (066_admin_catalogue_editor.sql, ajustable depuis le hub) : défaut 50%/35%/1
// = exactement le object-position codé en dur avant cette migration, donc aucune carte n'existante
// ne change de rendu tant qu'un modo/admin ne l'édite pas explicitement.
function cardImageStyle(g){
  const x = g.image_pos_x ?? 50, y = g.image_pos_y ?? 35, s = g.image_scale ?? 1;
  return 'object-position:' + x + '% ' + y + '%' + (s !== 1 ? ';transform:scale(' + s + ')' : '');
}
// Image de secours (assets/card-image-placeholder.png) quand l'URL réelle est cassée (404, lien
// mort) — remplace this.remove() qui laissait juste un fond vide sans indiquer le problème.
function cardImgFallback(){
  return 'this.onerror=null;this.src="assets/card-image-placeholder.png";this.style.objectPosition="50% 50%";this.style.transform="none"';
}
function cardHTML(g, o){
  o = o || {};
  const photo = g.image_url
    ? '<img src="' + esc(g.image_url) + '" alt="" loading="lazy" style="' + cardImageStyle(g) + '" onerror="' + cardImgFallback() + '">'
    : '<span>' + esc(initials(g.title)) + '</span>';
  const count = o.count > 1 ? '<b class="cnt">×' + o.count + '</b>' : "";
  const abbr = (typeof RARITY_ORDER !== "undefined" && RARITY_ORDER[g.rarity]) ? RARITY_ORDER[g.rarity].abbr : g.rarity_name[0];
  // Cartes Gold unique (voir 043_rpc_open_booster_gold.sql) : un seul exemplaire au monde, sans
  // lien avec la rareté normale de la carte — la bordure passe donc en or plutôt que dans la
  // couleur de rareté habituelle, et un ruban "UNIQUE" confirme le statut.
  const rc = o.gold ? "#f5c945" : g.rarity_color;
  const bg = CARD_BG[g.rarity] || CARD_BG[0];
  const ribbon = o.gold ? '<b class="gribbon">✨ Unique</b>' : "";
  // L'image passe en style inline directement sur .cc-body (pas via une variable CSS --cardbg) :
  // un url() posé dans une custom property se résout par rapport à la feuille de style qui
  // consomme la variable (card.css, dans web/css/), pas au document qui pose le style inline —
  // d'où des 404 vers /css/assets/... tant que c'était fait via --cardbg sur .card.
  return '<div class="card r' + g.rarity + (o.shiny ? " holo" : "") + (o.gold ? " gold" : "") + '" style="--pc:' + g.family_color + ';--rc:' + rc + '">' +
    ribbon +
    '<div class="cc-photo">' + photo + '</div>' +
    '<b class="cc-badge" role="img" aria-label="' + esc(g.rarity_name) + '" title="' + esc(g.rarity_name) + '">' + esc(abbr) + '</b>' +
    count +
    '<div class="cc-body" style="background-image:url(' + bg + ')">' +
      '<h4 class="cc-title">' + esc(g.title) + '</h4>' +
      (cardSubText(g) ? '<p class="cc-sub">' + esc(cardSubText(g)) + '</p>' : '') +
      '<div class="cc-stats">' +
        '<span class="cc-atk">' + ICON_SWORDS + fmt(g.atk) + '</span>' +
        '<span class="cc-def">' + ICON_SHIELD + fmt(g.def) + '</span>' +
      '</div>' +
    '</div></div>';
}

function ghostHTML(g){
  return '<div class="card ghost" style="--pc:' + g.family_color + ';--rc:' + g.rarity_color + '">' +
    '<div class="cc-photo"><span>?</span></div>' +
    '<b class="cc-badge" title="' + esc(g.rarity_name) + '">' + esc(g.rarity_name[0]) + '</b>' +
    '<div class="cc-body" style="background-image:url(' + (CARD_BG[g.rarity] || CARD_BG[0]) + ')">' +
      '<h4 class="cc-title">Carte inconnue</h4>' +
      '<div class="cc-stats">' +
        '<span class="cc-atk">' + ICON_SWORDS + '—</span>' +
        '<span class="cc-def">' + ICON_SHIELD + '—</span>' +
      '</div>' +
    '</div></div>';
}

function thumbHTML(g, sh){
  return '<span class="thumb' + (sh ? " holo-t" : "") + '" style="--pc:' + g.family_color + ';--rc:' + g.rarity_color + '" aria-hidden="true">' + esc(initials(g.title)) + '</span>';
}

/* Reflet des cartes brillantes au survol/toucher — copié tel quel de card-render.js. */
document.addEventListener("pointermove", (e) => {
  const cw = e.target.closest && e.target.closest(".cw");
  if (!cw || !cw.querySelector(".holo")) return;
  const r = cw.getBoundingClientRect();
  cw.classList.add("tracking");
  cw.style.setProperty("--hx", ((e.clientX - r.left) / r.width * 100).toFixed(1) + "%");
  cw.style.setProperty("--hy", ((e.clientY - r.top) / r.height * 100).toFixed(1) + "%");
}, { passive: true });

/* Notification éphémère — copiée de site/js/engine/market.js (toast), nécessite #toasts. */
function toast(msg){
  const box = document.getElementById("toasts");
  if (!box) return;
  const el = document.createElement("div");
  el.className = "toast";
  el.textContent = msg;
  box.appendChild(el);
  setTimeout(() => el.remove(), 2600);
}
