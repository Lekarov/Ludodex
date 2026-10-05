// Génère schema/catalogue_import/character_catalogue.csv à importer dans
// public.character_catalogue (voir 044/045_*.sql) via Table Editor > Insert > Import data from
// CSV. Catalogue séparé de card_catalogue (voir generate_card_catalogue.js) : des personnages,
// pas des jeux — pas de note IGDB à exploiter pour la rareté, donc score pseudo-aléatoire stable
// (hash32, copié de generate_card_catalogue.js) avec des bonus par franchise pour que les entrées
// notables (personnages spéciaux Animal Crossing, légendaires/mythiques/Méga Pokémon) montent
// naturellement vers les paliers de rareté hauts lors du tri percentile global.
//
// Franchises actuelles (toutes sans clé API, 43 362 fiches au total) :
// - Animal Crossing : 490 villageois + 76 personnages spéciaux (API Cargo publique Nookipedia).
// - Pokémon : 1 347 fiches (formes standards + Méga/Gigamax/régionales + légendaires/mythiques),
//   noms en français, depuis les CSV publics du dépôt GitHub PokeAPI/pokeapi.
// - League of Legends : 2 122 fiches (173 champions + leurs skins, chromas exclus), noms en
//   français, depuis l'API officielle et gratuite Riot Data Dragon.
// - Magic: The Gathering : ~20 000 fiches (créatures + planeswalkers, un par nom d'oracle unique),
//   rareté officielle du jeu, depuis l'API publique Scryfall.
// - Hearthstone : ~4 500 fiches (serviteurs + héros collectibles), noms en français, rareté
//   officielle du jeu, depuis HearthstoneJSON.
// - Dota 2 : 127 héros, noms en anglais (pas de source FR gratuite trouvée), via l'API OpenDota.
// - Yu-Gi-Oh! : ~9 400 fiches (monstres uniquement), via l'API publique YGOPRODeck.
// - Genshin Impact : ~97 personnages, noms en français + rareté officielle (4★/5★), via
//   dvaJi/genshin-data (noms) + ScobbleQ/HoYo-Assets (splash art), tous deux sur GitHub.
// - Honkai: Star Rail : 73 personnages, noms en anglais (pas de source FR gratuite trouvée), via
//   ScobbleQ/HoYo-Assets.
// - Valorant : 29 agents, noms en français, via l'API officielle et gratuite valorant-api.com.
// - Fortnite : ~2 800 skins de personnages, noms en français, rareté officielle du jeu, via
//   l'API gratuite fortnite-api.com.
// - Digimon : 1 488 fiches, noms romanisés (pas de FR), via l'API officielle et gratuite
//   digi-api.com.
// - Fate/Grand Order : 409 Servants, noms en anglais, vraie rareté du jeu, via la base
//   communautaire de référence Atlas Academy (api.atlasacademy.io).
// - Nintendo (Amiibo) : 200 personnages (Mario, Zelda, Metroid, Splatoon, Fire Emblem, Monster
//   Hunter, Street Fighter...), noms en anglais, via le dépôt GitHub N3evin/AmiiboAPI (id amiibo
//   décodé à la main, l'API web officielle étant down). Animal Crossing exclu (déjà couvert).
// - One Piece : 192 personnages (filtré à ≥10 favoris MyAnimeList sur les 1 477 de la fiche
//   anime, pour écarter le long traîne de figurants), noms en anglais (pas de FR gratuite), via
//   l'API non-officielle mais gratuite Jikan (api.jikan.moe, aucune clé requise).
// - Dofus (bestiaire) : 5 132 monstres, noms en français, via l'API publique et gratuite
//   api.dofusdb.fr (aucune clé requise). PNJ exclus : l'API n'expose qu'un code d'apparence
//   ("look") non rendu en image, aucun service public trouvé pour le transformer en PNG — voir
//   data/volumes/dofus_2026/ pour le détail. Type 'monster' par défaut, 'miniboss'/'boss' pour
//   les variantes marquées comme telles côté jeu (seul signal de notabilité disponible, pas de
//   rareté officielle pour un bestiaire).
//
// Usage : node generate_character_catalogue.js

const fs = require("fs");
const path = require("path");

const DATA_DIR = path.resolve(__dirname, "..", "..", "..", "data");

const SOURCES = [
  { file: "volumes/ac_villagers_2026/nookipedia_villagers_raw.json", type: "villager", scoreBonus: 0 },
  { file: "volumes/ac_special_characters_2026/nookipedia_special_characters_raw.json", type: "special", scoreBonus: 35 },
];

// Copié tel quel de generate_card_catalogue.js.
const RAR = [
  { name: "Commune", share: 0.40, mult: 1, color: "#7d879c" },
  { name: "Peu commune", share: 0.25, mult: 1.2, color: "#2f9e68" },
  { name: "Rare", share: 0.18, mult: 1.5, color: "#2f74d0" },
  { name: "Épique", share: 0.10, mult: 2, color: "#8a45d6" },
  { name: "Légendaire", share: 0.05, mult: 3, color: "#d99a14" },
  { name: "Mythique", share: 0.02, mult: 5, color: "#e0457b" },
];

// Une couleur de famille par espèce plutôt que par éditeur (pas de plateforme ici) — juste pour
// varier le fond de la fenêtre d'illustration (--pc), aucune signification fonctionnelle.
const SPECIES_COLOR = {
  Bird: "#3aa17e", Cat: "#e07a1a", "Bear cub": "#9b5b2e", Bear: "#9b5b2e", Cub: "#9b5b2e",
  Squirrel: "#6a3fd1", Goat: "#8a6d3b", Dog: "#2f8f3a", Duck: "#1a9e9e", Frog: "#1b8fc9",
  Rabbit: "#d6282b", Wolf: "#5b6272", Elephant: "#4a6fa5", Mouse: "#b8932a", Pig: "#e0457b",
  Sheep: "#8a6d3b", Horse: "#9b5b2e", Alligator: "#2f8f3a", Anteater: "#9b5b2e", Chicken: "#e07a1a",
  Cow: "#5b6272", Deer: "#9b5b2e", Eagle: "#3aa17e", Gorilla: "#5b6272", Hamster: "#b8932a",
  Hippo: "#4a6fa5", Koala: "#5b6272", Kangaroo: "#e07a1a", Lion: "#d99a14", Monkey: "#9b5b2e",
  Octopus: "#6a3fd1", Ostrich: "#3aa17e", Owl: "#8a6d3b", Penguin: "#1a9e9e", Rhino: "#5b6272",
  Rooster: "#e07a1a", Tiger: "#d6282b", Wolves: "#5b6272", Peacock: "#6a3fd1", Boar: "#9b5b2e",
  Alpaca: "#8a6d3b", Beaver: "#9b5b2e", Pigeon: "#b8932a", Tortoise: "#2f8f3a",
};

function hash32(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
// Slug + suffixe de hash court : deux noms distincts peuvent se réduire au même slug une fois la
// ponctuation retirée (ex. MTG "Rhino" et "Rhino-" un un-set, ou "Goblin // Soldier" et "Goblin
// Soldier"). Le hash sur le nom EXACT (avant slug) garantit l'unicité sans casser la lisibilité.
function slugName(name) {
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return slug + "-" + hash32(name).toString(36).slice(0, 6);
}

function placeholderStats(id) {
  const h1 = hash32(id + "#c"), h2 = hash32(id + "#p"), h3 = hash32(id + "#h");
  return { c: 45 + (h1 % 50), pop: 5 + (h2 % 90), h: 1 + (h3 % 60) };
}

const GAME_LABELS = {
  ac: "Animal Crossing", e_plus: "Animal Forest e+", ww: "Wild World", cf: "City Folk",
  nl: "New Leaf", wa: "New Leaf: Welcome amiibo", nh: "New Horizons", film: "Film",
  hhd: "Happy Home Designer", pc: "Pocket Camp", dnm: "Doubutsu no Mori", plus: "Doubutsu no Mori+",
};

function gamesList(row) {
  return Object.keys(GAME_LABELS)
    .filter((k) => row[k] === "1" || row[k] === 1 || row[k] === true)
    .map((k) => GAME_LABELS[k])
    .join(", ");
}

// Nom corrompu côté wiki (encodage cassé sur la page source) — corrigé manuellement, l'URL
// d'image ("Pav%C3%A9_NH.png") confirme qu'il s'agit bien de "Pavé".
const NAME_FIXES = { "Pav�": "Pavé" };

const entries = [];
for (const src of SOURCES) {
  const rows = JSON.parse(fs.readFileSync(path.join(DATA_DIR, src.file), "utf8"));
  for (const row of rows) {
    const name = NAME_FIXES[row.name] || row.name;
    if (!name || /^&lt;/.test(name)) continue; // entrée non nommée/test (ex. "<tt>xsq</tt>")
    if (!row.image_url) continue;
    // Deux villageois différents peuvent légitimement porter le même nom (ex. deux "Carmen" : une
    // souris et une lapine, jamais dans le même jeu) — l'espèce désambiguïse l'id sans quoi le
    // deuxième écraserait le premier lors de l'import (clé primaire en collision).
    const slug = (name + (row.species ? "-" + row.species : "")).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    const id = `ac:${src.type}:${slug}`;
    const { c, pop, h } = placeholderStats(id);
    entries.push({
      id, franchise: "Animal Crossing", type: src.type, name,
      species: row.species || null, personality: row.personality || null,
      gender: row.gender || null, birthday: row.birthday || null,
      quote: row.quote || null, games: gamesList(row) || null,
      image: row.image_url,
      score: c * 0.6 + pop * 0.4 + src.scoreBonus,
      familyColor: SPECIES_COLOR[row.species] || "#5b6272",
      pop, h,
    });
  }
}

// Pokémon (voir data/volumes/pokemon_2026/pokemon_consolidated.json, construit depuis les CSV
// publics du dépôt GitHub PokeAPI/pokeapi — 1 347 fiches, formes standards + Méga/Gigamax/
// régionales + légendaires/mythiques). Bonus de score empilables : plus une forme est notable,
// plus elle tend vers les paliers de rareté hauts, avec le même tri percentile que les jeux et
// Animal Crossing plus haut (un seul classement global sur tout character_catalogue).
const POKEMON_FILE = "volumes/pokemon_2026/pokemon_consolidated.json";
if (fs.existsSync(path.join(DATA_DIR, POKEMON_FILE))) {
  const rows = JSON.parse(fs.readFileSync(path.join(DATA_DIR, POKEMON_FILE), "utf8"));
  for (const row of rows) {
    const id = `pokemon:${row.identifier}`;
    const { c, pop, h } = placeholderStats(id);
    let bonus = 0;
    let type = "standard";
    if (row.is_mythical) { bonus = 55; type = "mythical"; }
    else if (row.is_legendary) { bonus = 42; type = "legendary"; }
    else if (row.is_mega) { bonus = 26; type = "mega"; }
    else if (row.is_gmax) { bonus = 20; type = "gmax"; }
    else if (row.is_regional_form) { bonus = 8; type = "regional"; }
    entries.push({
      id, franchise: "Pokémon", type, name: row.name,
      species: null, personality: null, gender: null, birthday: null,
      quote: null, games: row.generation || null,
      image: row.image_url,
      score: c * 0.6 + pop * 0.4 + bonus,
      familyColor: row.type_color || "#5b6272",
      pop, h,
    });
  }
}

// League of Legends (voir data/volumes/lol_2026/lol_champions_skins.json, construit depuis
// l'API officielle et gratuite Riot Data Dragon — 173 champions + leurs skins, noms en français,
// chromas exclus à la source car ils partagent le splash art de leur skin parent). Un skin non-
// par-défaut reçoit un bonus modeste : Riot n'expose pas de rareté de skin dans Data Dragon, donc
// pas de hiérarchie fine possible (juste "c'est un skin" vs "c'est l'apparence de base").
const ROLE_COLOR = {
  Fighter: "#c22e28", Mage: "#6390f0", Assassin: "#705746", Marksman: "#ee8130",
  Support: "#7ac74c", Tank: "#a8a878",
};
const LOL_FILE = "volumes/lol_2026/lol_champions_skins.json";
if (fs.existsSync(path.join(DATA_DIR, LOL_FILE))) {
  const rows = JSON.parse(fs.readFileSync(path.join(DATA_DIR, LOL_FILE), "utf8"));
  for (const row of rows) {
    const id = `lol:${row.champion_id}:${row.skin_num}`;
    const { c, pop, h } = placeholderStats(id);
    entries.push({
      id, franchise: "League of Legends", type: row.is_base_skin ? "standard" : "skin", name: row.name,
      species: row.role || null, personality: null, gender: null, birthday: null,
      quote: row.title || null, games: null,
      image: row.image_url,
      score: c * 0.6 + pop * 0.4 + (row.is_base_skin ? 0 : 15),
      familyColor: ROLE_COLOR[row.role] || "#5b6272",
      pop, h,
    });
  }
}

// Sources supplémentaires "sans clé API" : chacune associe son propre bonus de score à la vraie
// rareté du jeu source quand elle existe (Magic, Hearthstone, Genshin), sinon score neutre
// (Dota 2, Yu-Gi-Oh!, Honkai Star Rail — pas de champ de rareté fixe exploitable côté source).
function addSimpleFranchise(file, franchise, mapRow) {
  const full = path.join(DATA_DIR, file);
  if (!fs.existsSync(full)) return;
  const rows = JSON.parse(fs.readFileSync(full, "utf8"));
  for (const row of rows) {
    const mapped = mapRow(row);
    if (!mapped) continue;
    const { idPart, name, type, bonus, familyColor, quote, species } = mapped;
    const id = `${franchise.toLowerCase().replace(/[^a-z0-9]+/g, "")}:${idPart}`;
    const { c, pop, h } = placeholderStats(id);
    entries.push({
      id, franchise, type: type || "standard", name,
      species: species || null, personality: null, gender: null, birthday: null,
      quote: quote || null, games: null,
      image: row.image_url,
      score: c * 0.6 + pop * 0.4 + (bonus || 0),
      familyColor: familyColor || "#5b6272",
      pop, h,
    });
  }
}

// Magic: The Gathering (Scryfall, cartes Créature/Planeswalker uniques par nom d'oracle).
const MTG_COLOR = { White: "#d6c48a", Blue: "#3b74e0", Black: "#4a4550", Red: "#c22e28", Green: "#2f8f3a" };
const MTG_BONUS = { common: 0, uncommon: 6, rare: 16, mythic: 32, special: 20 };
const MTG_TYPE = { mythic: "mythical", rare: "legendary" };
addSimpleFranchise("volumes/mtg_2026/mtg_consolidated.json", "Magic: The Gathering", (row) => ({
  idPart: slugName(row.name), // deux noms distincts peuvent partager le même slug (ex. "Rhino"
  // et "Rhino-" un un-set) — slugName ajoute un suffixe de hash pour garantir l'unicité.
  name: row.name, type: MTG_TYPE[row.rarity_mtg], bonus: MTG_BONUS[row.rarity_mtg] || 0,
  familyColor: MTG_COLOR[row.color] || "#5b6272", quote: row.type_line, species: row.set_name,
}));

// Hearthstone (HearthstoneJSON, noms en français).
const HS_BONUS = { FREE: 0, COMMON: 0, RARE: 8, EPIC: 16, LEGENDARY: 32 };
const HS_TYPE = { LEGENDARY: "legendary" };
addSimpleFranchise("volumes/hearthstone_2026/hearthstone_consolidated.json", "Hearthstone", (row) => ({
  idPart: slugName(row.name) + ":" + row.type.toLowerCase(),
  name: row.name, type: HS_TYPE[row.hs_rarity], bonus: HS_BONUS[row.hs_rarity] || 0,
  familyColor: "#5b6272", quote: row.cardClass, species: row.race,
}));

// Dota 2 (OpenDota, noms en anglais — pas de source FR gratuite trouvée).
addSimpleFranchise("volumes/dota2_2026/dota2_consolidated.json", "Dota 2", (row) => ({
  idPart: row.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, ""),
  name: row.name, species: (row.roles || [])[0], quote: row.primary_attr,
}));

// Yu-Gi-Oh! (YGOPRODeck, monstres uniquement, avec vrais ATK/DEF du jeu conservés en note mais
// pas réinjectés dans nos stats — voir placeholderStats, même logique que les autres franchises).
addSimpleFranchise("volumes/yugioh_2026/yugioh_consolidated.json", "Yu-Gi-Oh!", (row) => ({
  idPart: row.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, ""),
  name: row.name, species: row.race, quote: row.attribute,
}));

// Genshin Impact (dvaJi/genshin-data pour les noms FR + rareté officielle, splash art via
// ScobbleQ/HoYo-Assets).
const GENSHIN_ELEMENT_COLOR = {
  Pyro: "#c22e28", Hydro: "#3b74e0", Anemo: "#7ac74c", Electro: "#a98ff3",
  Cryo: "#96d9d6", Géo: "#e2bf65", Dendro: "#7ac74c",
};
addSimpleFranchise("volumes/genshin_2026/genshin_consolidated.json", "Genshin Impact", (row) => ({
  idPart: String(row.id),
  name: row.name, type: row.rarity === 5 ? "legendary" : "standard", bonus: row.rarity === 5 ? 28 : 10,
  familyColor: GENSHIN_ELEMENT_COLOR[row.element] || "#5b6272", quote: row.title, species: row.region,
}));

// Honkai: Star Rail (ScobbleQ/HoYo-Assets, noms en anglais — pas de source FR gratuite trouvée).
addSimpleFranchise("volumes/hsr_2026/hsr_consolidated.json", "Honkai: Star Rail", (row) => ({
  idPart: String(row.id), name: row.name,
}));

// Valorant (valorant-api.com, officielle et gratuite, noms en français).
addSimpleFranchise("volumes/valorant_2026/valorant_consolidated.json", "Valorant", (row) => ({
  idPart: slugName(row.name), name: row.name, species: row.role,
}));

// Fortnite (fortnite-api.com, skins de personnages "outfit" uniquement, noms en français, vraie
// rareté du jeu — les séries crossover sous licence (Marvel/DC/Star Wars) gardent leur bonus
// propre plutôt que d'être exclues, ce sont des skins Fortnite avant tout).
const FN_BONUS = {
  common: 0, uncommon: 4, rare: 10, epic: 18, legendary: 30, icon: 26,
  marvel: 22, dc: 22, starwars: 22, gaminglegends: 20, frozen: 14, lava: 14, dark: 14, slurp: 10, shadow: 14,
};
const FN_TYPE = { legendary: "legendary", icon: "legendary" };
addSimpleFranchise("volumes/fortnite_2026/fortnite_consolidated.json", "Fortnite", (row) => ({
  idPart: slugName(row.name), name: row.name, type: FN_TYPE[row.rarity_fn],
  bonus: FN_BONUS[row.rarity_fn] || 8, quote: row.rarity_fn,
}));

// Digimon (digi-api.com, officielle et gratuite, noms en anglais/romanisés — pas de FR).
addSimpleFranchise("volumes/digimon_2026/digimon_consolidated.json", "Digimon", (row) => ({
  idPart: slugName(row.name), name: row.name,
}));

// Fate/Grand Order (Atlas Academy, base de données communautaire de référence pour la série,
// noms en anglais, vraie rareté du jeu en étoiles).
const FGO_BONUS = { 0: 0, 1: 0, 2: 2, 3: 6, 4: 16, 5: 30 };
const FGO_TYPE = { 5: "legendary" };
addSimpleFranchise("volumes/fgo_2026/fgo_consolidated.json", "Fate/Grand Order", (row) => ({
  idPart: slugName(row.name), name: row.name, type: FGO_TYPE[row.rarity],
  bonus: FGO_BONUS[row.rarity] || 0, species: row.class_name,
}));

// Nintendo (& invités tiers) via les figurines Amiibo (dépôt GitHub N3evin/AmiiboAPI, id decodé
// à la main — l'API web officielle semble down). Couvre Mario, Zelda, Metroid, Splatoon, Fire
// Emblem, Monster Hunter, Street Fighter, Shovel Knight, etc. La série Animal Crossing (cartes
// amiibo, 476 personnages) est exclue à la source : ce sont les mêmes villageois déjà importés
// depuis Nookipedia, pas de nouveaux personnages.
addSimpleFranchise("volumes/amiibo_2026/amiibo_consolidated.json", "Nintendo (Amiibo)", (row) => ({
  idPart: slugName(row.name), name: row.name, species: row.series,
  bonus: row.variant_count > 3 ? 10 : 0, // plusieurs figurines = personnage plus notable
}));

// One Piece (Jikan, API non-officielle mais gratuite/sans clé pour MyAnimeList — personnages de
// l'anime, filtrés à "au moins 10 favoris MAL" pour écarter le très long traîne de figurants
// nommés une fois (925 des 1 477 personnages de la fiche ont 0 favori) : 192 fiches gardées,
// vérifiées une à une par vrai GET (pas de lien mort). Pas de nom français disponible via cette
// source (comme Dota/Digimon/HSR). Bonus de notabilité = rôle "Main" + paliers de favoris,
// substitut du "rôle" du personnage faute de rareté officielle de jeu ici (ce sont des cartes
// tirées d'un anime, pas d'un jeu à système de rareté).
// MAL stocke certains noms "Nom de famille, Prénom" (ex. "Monkey D., Luffy") — remplacer la
// virgule par un espace retombe pile sur le nom usuel ("Monkey D. Luffy"), pas besoin de logique
// plus complexe.
addSimpleFranchise("volumes/onepiece_2026/onepiece_consolidated.json", "One Piece", (row) => {
  let bonus = row.role === "Main" ? 15 : 0;
  if (row.favorites >= 5000) bonus += 25;
  else if (row.favorites >= 1000) bonus += 15;
  else if (row.favorites >= 300) bonus += 8;
  else if (row.favorites >= 100) bonus += 4;
  const name = row.name.replace(", ", " ");
  return {
    idPart: slugName(name), name,
    type: row.role === "Main" && row.favorites >= 1000 ? "legendary" : "standard",
    bonus, quote: row.role,
  };
});

// Overwatch (OverFast API, wrapper communautaire gratuit et sans clé autour de la page héros
// officielle Blizzard — vérifié : 53 héros, chaque portrait confirmé par vrai GET, pas de HEAD).
// Pas de rareté officielle (pas des cartes à collectionner côté jeu source) : le rôle (tank/
// dégâts/soutien) sert de "species" à la place, aucun bonus de notabilité entre héros.
addSimpleFranchise("volumes/overwatch_2026/overwatch_consolidated.json", "Overwatch", (row) => ({
  idPart: slugName(row.name), name: row.name, species: row.role, quote: row.subrole,
}));

// Warframe (api.warframestat.us, gratuite et sans clé) : son champ image direct "wikiaThumbnail"
// n'est renseigné que sur 7 des 126 entrées de l'API — reconstruit à la place l'URL réelle du wiki
// officiel (wiki.warframe.com/images/<Nom sans espace ni ponctuation>.png, le suffixe de cache
// est optionnel) et vérifiée une à une par vrai GET (121/121 résolvent une fois les caractères non
// alphanumériques retirés du nom, ex. "Cyte-09" -> "Cyte09.png"). Catégorie "Warframes"
// uniquement (combat au sol, variantes Primes incluses) : Archwing/Necramech/objets spéciaux
// exclus au tri, hors sujet pour des "personnages". Les Primes (dorées, plus notables/recherchées
// in-game) reçoivent un bonus de rareté, seul signal de notabilité disponible côté source.
addSimpleFranchise("volumes/warframe_2026/warframe_consolidated.json", "Warframe", (row) => ({
  idPart: slugName(row.name), name: row.name,
  type: row.isPrime ? "legendary" : "standard", bonus: row.isPrime ? 20 : 0,
}));

// Dofus (api.dofusdb.fr, bestiaire uniquement — voir note en haut de fichier pour les PNJ
// exclus). Pas de rareté officielle côté jeu source : boss/mini-boss servent de signal de
// notabilité, comme légendaire/mythique ailleurs. La famille (race) sert de "species" pour la
// couleur de fond, avec une palette cyclique faute de couleur élémentaire fiable par monstre.
const DOFUS_RACE_PALETTE = [
  "#7d879c", "#2f9e68", "#2f74d0", "#8a45d6", "#d99a14", "#e0457b",
  "#c22e28", "#3aa17e", "#9b5b2e", "#1a9e9e", "#6a3fd1", "#8a6d3b",
];
addSimpleFranchise("volumes/dofus_2026/dofus_monsters_consolidated.json", "Dofus", (row) => {
  let type = "monster", bonus = 0;
  if (row.is_boss) { type = "boss"; bonus = 30; }
  else if (row.is_miniboss) { type = "miniboss"; bonus = 14; }
  else if ((row.max_level || 0) >= 150) { bonus = 6; }
  const raceColor = row.race_name
    ? DOFUS_RACE_PALETTE[hash32(row.race_name) % DOFUS_RACE_PALETTE.length]
    : "#5b6272";
  return {
    idPart: String(row.id), name: row.name, type, bonus,
    familyColor: raceColor, species: row.race_name,
    quote: row.max_level ? `Niveau ${row.level}-${row.max_level}` : `Niveau ${row.level}`,
  };
});

const idCounts = {};
entries.forEach((e) => { idCounts[e.id] = (idCounts[e.id] || 0) + 1; });
const dupes = Object.entries(idCounts).filter(([, n]) => n > 1);
if (dupes.length) {
  throw new Error(`character_id en collision (clé primaire) : ${dupes.map(([id, n]) => `${id} (${n}x)`).join(", ")}`);
}

const order = [...entries].sort((a, b) => b.score - a.score);
entries.forEach((e) => { e.r = 0; });
let idx = 0;
for (let r = RAR.length - 1; r >= 1; r--) {
  const n = Math.max(1, Math.round(RAR[r].share * entries.length));
  for (let k = 0; k < n && idx < order.length; k++, idx++) order[idx].r = r;
}

entries.forEach((e) => {
  const m = RAR[e.r].mult;
  e.atk = Math.round(e.pop * 20 * m / 10) * 10;
  e.def = Math.round((100 + Math.log10(e.h + 1) * 450) * m / 10) * 10;
});

function csvField(v) {
  if (v === null || v === undefined) return "";
  const s = String(v);
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

const outPath = path.join(__dirname, "character_catalogue.csv");
const header = ["character_id", "franchise", "character_type", "name", "species", "personality", "gender", "birthday", "quote", "games", "rarity", "rarity_name", "rarity_color", "family_color", "image_url", "atk", "def"];
const lines = [header.join(",")];
const byR = RAR.map(() => 0);
for (const e of entries) {
  byR[e.r]++;
  const rar = RAR[e.r];
  const row = [
    e.id, e.franchise, e.type, e.name, e.species, e.personality, e.gender, e.birthday, e.quote, e.games,
    e.r, rar.name, rar.color, e.familyColor, e.image, e.atk, e.def,
  ];
  lines.push(row.map(csvField).join(","));
}

fs.writeFileSync(outPath, lines.join("\n") + "\n", "utf8");
console.log(`Écrit ${entries.length} lignes dans ${outPath}`);

RAR.forEach((r, i) => console.log(`  ${r.name} (r=${i}) : ${byR[i]}`));
