// Génère schema/catalogue_import/card_catalogue.csv à importer dans public.card_catalogue (voir
// 015_card_catalogue_display_fields.sql) via Table Editor > Insert > Import data from CSV.
// Rejoue exactement la logique de site/js/data/catalogue-loader.js (hash32, computeStats,
// assignRarity, pickPlatform, calcul ATK/DEF) et site/js/config/constants.js (RAR, PLAT_PRIORITY,
// FAM) pour que la fiche stockée en base corresponde à ce que le site afficherait pour la même
// carte. card_id = `id` stable des sources (ex. "igdb:12345"), jamais l'index de tableau utilisé
// côté client — voir passation à l'utilisateur du 26/09/2026 pour le pourquoi.
//
// Contient maintenant aussi les champs d'affichage (titre, plateforme, image, ATK/DEF...) : le
// client (jeu.js) ne télécharge plus tout le catalogue, juste les cartes qu'il affiche
// réellement, via une requête Supabase sur cette table.
//
// À relancer et à réimporter (table vidée par 015 à chaque refonte du schéma, ou à vider/rejouer
// manuellement) chaque fois que le catalogue change de façon notable : la rareté est un
// classement par percentile sur tout le catalogue, pas un attribut fixe par carte.
//
// Usage : node generate_card_catalogue.js

const fs = require("fs");
const path = require("path");

const DATA_DIR = path.resolve(__dirname, "..", "..", "..", "data");

// Le dernier fichier de la liste qui définit une clé donnée l'emporte en cas de collision
// (même logique que l'ancien loadCatalogue() du prototype archivé). En pratique chaque nouveau
// volume est dédoublonné en amont contre tous les existants avant d'être écrit (voir son propre
// rapport sous data/volumes/<volume>/), donc l'ordre ne change rien aujourd'hui — gardé par
// prudence si cette garantie venait à manquer un jour.
const CATALOGUE_SOURCES = [
  "volumes/igdb_massif_14663/ludodex_igdb_massif.json",
  "volumes/volume_2/ludodex_volume_2.json",
  "ludodex_catalogue.json",
  "volumes/igdb_volume_3_10015/ludodex_igdb_volume_3.json",
  "volumes/igdb_recent_2020_2026/ludodex_igdb_recent_2020_2026.json",
  "volumes/igdb_recent_2020_2026_2/ludodex_igdb_recent_2020_2026_2.json",
  "volumes/igdb_gamecube_ds_psp/ludodex_igdb_gamecube_ds_psp.json",
  "volumes/igdb_ps2_wii_3ds_vita_dreamcast_gba/ludodex_igdb_ps2_wii_3ds_vita_dreamcast_gba.json",
  "volumes/igdb_ps3_ps4_x360_xone_wiiu_switch/ludodex_igdb_ps3_ps4_x360_xone_wiiu_switch.json",
  "volumes/igdb_modern_rare/ludodex_igdb_modern_rare.json",
  "volumes/igdb_modern_2026/ludodex_igdb_modern_2026.json", // +396 jeux modernes, 27/09/2026
  "volumes/igdb_exhaustif_2026/ludodex_igdb_exhaustif_2026.json", // +170 559 jeux (extraction exhaustive zéro-avis, mobile/web-only exclu), 27/09/2026
  "volumes/igdb_modern_rated_2026/ludodex_igdb_modern_rated_2026.json", // +8 jeux (modernes notés, plateformes élargies mobile/VR/cloud), 27/09/2026
  "volumes/igdb_flops_aaa/ludodex_igdb_flops_aaa.json", // +2 jeux (flops AAA studios connus : Warcraft III Reforged, Hyenas annulé), 27/09/2026
  "volumes/igdb_playstation_gap_2026/ludodex_igdb_playstation_gap_2026.json", // +833 jeux (trou PS1-PS5/Vita/PSP comblé, contenu adulte déjà exclu à la source), 28/09/2026
];

// Copié tel quel depuis site/js/config/constants.js — ne pas changer sans changer aussi le site.
const RAR = [
  { name: "Commune", share: 0.40, mult: 1, color: "#7d879c" },
  { name: "Peu commune", share: 0.25, mult: 1.2, color: "#2f9e68" },
  { name: "Rare", share: 0.18, mult: 1.5, color: "#2f74d0" },
  { name: "Épique", share: 0.10, mult: 2, color: "#8a45d6" },
  { name: "Légendaire", share: 0.05, mult: 3, color: "#d99a14" },
  { name: "Mythique", share: 0.02, mult: 5, color: "#e0457b" },
];
const FAM = { nintendo: "#d6282b", sony: "#2d5bd3", microsoft: "#2f8f3a", sega: "#1b8fc9", pc: "#5b6272", arcade: "#e07a1a", atari: "#9b5b2e", snk: "#b8932a", mobile: "#3aa17e", vr: "#6a3fd1", web: "#1a9e9e", cloud: "#4a6fa5", retro: "#8a6d3b" };
const PLAT_PRIORITY = [
  [/^Nintendo Switch 2$/, "switch2", "Switch 2", "nintendo"],
  [/^Nintendo Switch$/, "switch", "Switch", "nintendo"],
  [/^Switch$/, "switch", "Switch", "nintendo"],
  [/^PlayStation 5$/, "ps5", "PlayStation 5", "sony"],
  [/^PlayStation VR2$/, "psvr2", "PS VR2", "sony"],
  [/^PlayStation VR$/, "psvr", "PS VR", "sony"],
  [/^Xbox Series/, "xs", "Xbox Series X/S", "microsoft"],
  [/^S$/, "xs", "Xbox Series X/S", "microsoft"],
  [/^Xbox One/, "xone", "Xbox One", "microsoft"],
  [/^PlayStation 4$/, "ps4", "PlayStation 4", "sony"],
  [/^Wii U$/, "wiiu", "Wii U", "nintendo"],
  [/^Wii$/, "wii", "Wii", "nintendo"],
  [/^PlayStation 3$/, "ps3", "PlayStation 3", "sony"],
  [/^Xbox 360$/, "x360", "Xbox 360", "microsoft"],
  [/^PlayStation Vita$/, "vita", "PS Vita", "sony"],
  [/Nintendo 3DS/, "n3ds", "Nintendo 3DS", "nintendo"],
  [/Nintendo DSi?$/, "ds", "Nintendo DS", "nintendo"],
  [/GameCube/, "gc", "GameCube", "nintendo"],
  [/^Nintendo 64$/, "n64", "Nintendo 64", "nintendo"],
  [/^PlayStation 2$/, "ps2", "PlayStation 2", "sony"],
  [/^PlayStation$/, "ps1", "PlayStation", "sony"],
  [/^Dreamcast$/, "dc", "Dreamcast", "sega"],
  [/Saturn/, "saturn", "Saturn", "sega"],
  [/Mega Drive|Genesis/, "md", "Mega Drive", "sega"],
  [/Game Gear/, "gg", "Game Gear", "sega"],
  [/Master System/, "sms", "Master System", "sega"],
  [/Sega CD|^32X$|Sega 32X/, "segacd", "Sega CD / 32X", "sega"],
  [/Game Boy Advance/, "gba", "Game Boy Advance", "nintendo"],
  [/Game Boy Color/, "gbc", "Game Boy Color", "nintendo"],
  [/^Game Boy$/, "gb", "Game Boy", "nintendo"],
  [/Super Nintendo|Super Famicom|^Super NES/, "snes", "Super Nintendo", "nintendo"],
  [/^NES$|Nintendo Entertainment System|Family Computer(?! Disk)/, "nes", "NES", "nintendo"],
  [/Neo Geo/, "neogeo", "Neo Geo", "snk"],
  [/^Arcade$/, "arcade", "Arcade", "arcade"],
  [/Atari 2600/, "atari", "Atari 2600", "atari"],
  [/^Atari/, "atariother", "Atari (autre)", "atari"],
  [/PlayStation Portable|^PSP$/, "psp", "PSP", "sony"],
  [/3DO/, "3do", "3DO", "arcade"],
  [/Quest|PlayStation VR|Oculus|Windows Mixed Reality|SteamVR|visionOS|Daydream|Gear VR/, "vr", "Réalité virtuelle", "vr"],
  [/^iOS$|^Android$|Windows Phone|BlackBerry OS|Legacy Mobile Device|Windows Mobile/, "mobile", "Mobile", "mobile"],
  [/Web browser/, "web", "Navigateur", "web"],
  [/Stadia|OnLive/, "cloud", "Cloud", "cloud"],
  [/^Xbox$/, "xbox", "Xbox", "microsoft"],
  [/PC \(Microsoft Windows\)|PC \(Windows\)|^PC$|Steam \(PC\)|^DOS$|^Mac$|^macOS$|^Linux$/, "pc", "PC", "pc"],
];

function pickPlatform(list) {
  for (const [re, code, name, fam] of PLAT_PRIORITY) {
    if (list.find((p) => re.test(p))) return { name, family: fam };
  }
  const raw = list[0] || "Inconnue";
  return { name: raw, family: "retro" };
}

// Copié tel quel depuis site/js/data/catalogue-loader.js.
function hash32(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
function placeholderStats(id) {
  const h1 = hash32(id + "#c"), h2 = hash32(id + "#p"), h3 = hash32(id + "#h");
  return { c: 45 + (h1 % 50), pop: 5 + (h2 % 90), h: 1 + (h3 % 60) };
}
function computeStats(e) {
  const ph = placeholderStats(e.id);
  let c = ph.c, pop = ph.pop;
  const sel = e.selection;
  if (sel && typeof sel.rating === "number") {
    c = Math.max(1, Math.min(99, Math.round(sel.rating)));
    pop = Math.max(1, Math.min(99, Math.round(15 + 12 * Math.log2((sel.rating_count || 0) + 1))));
  } else if (sel && typeof sel.steamspy_positive_reviews === "number") {
    const pos = sel.steamspy_positive_reviews, neg = sel.steamspy_negative_reviews || 0;
    const ratio = sel.steamspy_positive_ratio != null ? sel.steamspy_positive_ratio : pos / Math.max(1, pos + neg);
    c = Math.max(1, Math.min(99, Math.round(ratio * 100)));
    pop = Math.max(1, Math.min(99, Math.round(15 + 9 * Math.log2(pos + neg + 1))));
  }
  return { c, pop, h: ph.h };
}

// Politique de contenu Ludodex : aucun contenu adulte/érotique, jamais (voir
// data/volumes/exclusions_content/*.json pour le détail par lot). Ces fichiers listent des
// card_id à retirer du catalogue final quelle que soit la source qui les a introduits.
const EXCLUSIONS_DIR = path.join(DATA_DIR, "volumes", "exclusions_content");
const excludedIds = new Set();
if (fs.existsSync(EXCLUSIONS_DIR)) {
  for (const name of fs.readdirSync(EXCLUSIONS_DIR)) {
    if (!name.endsWith(".json")) continue;
    const { excluded_card_ids } = JSON.parse(fs.readFileSync(path.join(EXCLUSIONS_DIR, name), "utf8"));
    (excluded_card_ids || []).forEach((id) => excludedIds.add(id));
  }
}

const merged = {};
let collisions = 0;
let excludedCount = 0;
for (const rel of CATALOGUE_SOURCES) {
  const file = path.join(DATA_DIR, rel);
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const key of Object.keys(json)) {
    if (excludedIds.has(key)) { excludedCount++; continue; }
    if (merged[key] !== undefined) collisions++;
    merged[key] = json[key];
  }
}

const entries = Object.values(merged).map((e) => {
  const { c, pop, h } = computeStats(e);
  const plats = e.platforms && e.platforms.length ? e.platforms : ["Inconnue"];
  const { name: platformName, family } = pickPlatform(plats);
  const img = (e.cover && (e.cover.url || e.cover.square_url)) || null;
  return {
    id: e.id,
    s: c * 0.6 + pop * 0.4,
    r: 0,
    pop,
    h,
    title: e.title || "(titre inconnu)",
    platformName,
    family,
    year: e.year || null,
    developer: e.developer || null,
    img,
    genres: (e.genres && e.genres.length) ? e.genres.join(", ") : null,
  };
});

// Même algorithme que assignRarity() dans catalogue-loader.js : trie par score décroissant,
// remplit les tranches de la plus rare à la plus commune selon `share`.
const order = [...entries].sort((a, b) => b.s - a.s);
let idx = 0;
for (let r = RAR.length - 1; r >= 1; r--) {
  const n = Math.max(1, Math.round(RAR[r].share * entries.length));
  for (let k = 0; k < n && idx < order.length; k++, idx++) order[idx].r = r;
}

// Même formule que catalogue-loader.js pour ATK/DEF (calculée une fois la rareté finale connue,
// puisque le multiplicateur en dépend).
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

const outPath = path.join(__dirname, "card_catalogue.csv");
const header = ["card_id", "rarity", "rarity_name", "rarity_color", "family_color", "title", "platform_name", "year", "developer", "image_url", "atk", "def", "genres"];
const lines = [header.join(",")];

const byR = RAR.map(() => 0);
for (const e of entries) {
  byR[e.r]++;
  const rar = RAR[e.r];
  const row = [
    e.id,
    e.r,
    rar.name,
    rar.color,
    FAM[e.family] || FAM.retro,
    e.title,
    e.platformName,
    e.year,
    e.developer,
    e.img,
    e.atk,
    e.def,
    e.genres,
  ];
  lines.push(row.map(csvField).join(","));
}

fs.writeFileSync(outPath, lines.join("\n") + "\n", "utf8");

console.log(`Écrit ${entries.length} lignes dans ${outPath} (collisions de clé ignorées : ${collisions}, exclus par politique de contenu : ${excludedCount})`);
RAR.forEach((r, i) => console.log(`  ${r.name} (r=${i}) : ${byR[i]}`));
