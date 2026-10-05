// Drapeaux de prototype (visuels en cours de validation). Extrait de ludodex.html sans changement de valeur.
// USE_FULL_ART_CARDS retiré le 27/09/2026 : direction abandonnée, remplacée par la DA actuelle
// (cartouche titre overlay, badge losange) — voir card.css/card-render.js, plus de bascule.
const USE_NEW_GOLD_VISUAL = true; // Prototype : activer seulement apres validation
document.documentElement.classList.toggle("newGoldVisual",USE_NEW_GOLD_VISUAL);
const USE_CARD_BACK_REVEAL = true; // Dos de carte + retournement 3D a l'ouverture ; repli sur l'ancien affichage direct si false
document.documentElement.classList.toggle("cardBackReveal",USE_CARD_BACK_REVEAL);
