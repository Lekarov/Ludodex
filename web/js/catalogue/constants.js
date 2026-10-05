// Constantes de configuration : boosters, raretés, plateformes, sources du catalogue, économie.
// Extrait de ludodex.html sans changement de valeur.
const MAX_PACKS = 10;           // stock maximum de boosters
const REGEN_MS  = 10 * 60 * 1000; // 1 booster toutes les 10 minutes
const GOLD_EVERY = 10;          // le 10e booster est doré
const SHINY_RATE = 1/20;        // chance qu'une carte tirée soit brillante (5 %)
const SHINY_MULT = 3;           // valeur d'une brillante par rapport à la version normale
const RAR = [
  {name:"Commune",     share:.40, mult:1,   color:"#7d879c"},
  {name:"Peu commune", share:.25, mult:1.2, color:"#2f9e68"},
  {name:"Rare",        share:.18, mult:1.5, color:"#2f74d0"},
  {name:"Épique",      share:.10, mult:2,   color:"#8a45d6"},
  {name:"Légendaire",  share:.05, mult:3,   color:"#d99a14"},
  {name:"Mythique",    share:.02, mult:5,   color:"#e0457b"},
];
// Probabilités de rareté par emplacement (en %)
const W_NORMAL = [55, 25, 13, 5, 1.7, 0.3];  // cartes 1 à 4
const W_LAST   = [0, 62, 25, 9, 3.3, 0.7];   // carte 5 : au moins Peu commune
const W_GOLD   = [0, 0, 62, 26, 9, 3];       // booster doré : au moins Rare
const FAM = {nintendo:"#d6282b", sony:"#2d5bd3", microsoft:"#2f8f3a", sega:"#1b8fc9", pc:"#5b6272", arcade:"#e07a1a", atari:"#9b5b2e", snk:"#b8932a", mobile:"#3aa17e", vr:"#6a3fd1", web:"#1a9e9e", cloud:"#4a6fa5", retro:"#8a6d3b"};
const PLAT = {
  atari:{n:"Atari 2600",f:"atari"}, arcade:{n:"Arcade",f:"arcade"}, neogeo:{n:"Neo Geo",f:"snk"},
  nes:{n:"NES",f:"nintendo"}, md:{n:"Mega Drive",f:"sega"}, gb:{n:"Game Boy",f:"nintendo"},
  snes:{n:"Super Nintendo",f:"nintendo"}, saturn:{n:"Saturn",f:"sega"}, ps1:{n:"PlayStation",f:"sony"},
  n64:{n:"Nintendo 64",f:"nintendo"}, dc:{n:"Dreamcast",f:"sega"}, ps2:{n:"PlayStation 2",f:"sony"},
  gba:{n:"Game Boy Advance",f:"nintendo"}, gc:{n:"GameCube",f:"nintendo"}, xbox:{n:"Xbox",f:"microsoft"},
  ds:{n:"Nintendo DS",f:"nintendo"}, psp:{n:"PSP",f:"sony"}, x360:{n:"Xbox 360",f:"microsoft"},
  wii:{n:"Wii",f:"nintendo"}, ps3:{n:"PlayStation 3",f:"sony"}, ps4:{n:"PlayStation 4",f:"sony"},
  switch:{n:"Switch",f:"nintendo"}, xs:{n:"Xbox One / Series",f:"microsoft"}, ps5:{n:"PlayStation 5",f:"sony"},
  pc:{n:"PC",f:"pc"},
};
// Complété dynamiquement par loadCatalogue() une fois les catalogues chargés
// (voir PLAT_PRIORITY plus bas) : les ~165 autres plateformes rencontrées dans
// les trois fichiers sources sont ajoutées à ce même objet au chargement.
const CATALOGUE_SOURCES = [
  {url:"data/volumes/igdb_massif_14663/ludodex_igdb_massif.json", label:"catalogue massif IGDB"},
  {url:"data/volumes/volume_2/ludodex_volume_2.json", label:"volume 2"},
  {url:"data/ludodex_catalogue.json", label:"catalogue principal"},
  {url:"data/volumes/igdb_volume_3_10015/ludodex_igdb_volume_3.json", label:"volume 3"},
  {url:"data/volumes/igdb_recent_2020_2026/ludodex_igdb_recent_2020_2026.json", label:"jeux récents 2020-2026"},
  {url:"data/volumes/igdb_recent_2020_2026_2/ludodex_igdb_recent_2020_2026_2.json", label:"jeux récents 2020-2026 (suite)"},
  {url:"data/volumes/igdb_gamecube_ds_psp/ludodex_igdb_gamecube_ds_psp.json", label:"GameCube DS PSP"},
  {url:"data/volumes/igdb_ps2_wii_3ds_vita_dreamcast_gba/ludodex_igdb_ps2_wii_3ds_vita_dreamcast_gba.json", label:"PS2 Wii 3DS Vita Dreamcast GBA"},
  {url:"data/volumes/igdb_ps3_ps4_x360_xone_wiiu_switch/ludodex_igdb_ps3_ps4_x360_xone_wiiu_switch.json", label:"PS3 PS4 Xbox Wii U Switch"},
  {url:"data/volumes/igdb_modern_rare/ludodex_igdb_modern_rare.json", label:"sélection raretés consoles modernes"},
];
// Fichiers séparés, chargés à part : ce sont des SURCOUCHES (id -> {description}) à fusionner
// champ par champ dans les jeux déjà connus, jamais des sources de catalogue à part entière —
// elles ne contiennent ni titre, ni plateforme, ni jaquette. Voir loadCatalogue().
// Surcouche jaquettes : id -> {coverUrl?, objectPosition?}, écrite par l'outil externe
// LudodexCoverEditor (App DoktorTV/LudodexCoverEditor). Fichier optionnel : absent ou
// vide tant qu'aucune correction n'a été faite, jamais une source de catalogue.
const COVER_OVERRIDES_URL = "assets/overrides/cover-overrides.json";
const DESCRIPTION_SOURCES = [
  {url:"coordination/descriptions_igdb_massif_14663.json", label:"descriptions IGDB massif"},
  {url:"coordination/descriptions_igdb_volume_3_10015.json", label:"descriptions IGDB volume 3"},
  {url:"coordination/descriptions_igdb_recent_2020_2026.json", label:"descriptions jeux récents"},
  {url:"coordination/descriptions_igdb_recent_2020_2026_2.json", label:"descriptions jeux récents (suite)"},
  {url:"coordination/descriptions_igdb_gamecube_ds_psp.json", label:"descriptions GameCube DS PSP"},
  {url:"coordination/descriptions_igdb_ps2_wii_3ds_vita_dreamcast_gba.json", label:"descriptions PS2 Wii 3DS Vita Dreamcast GBA"},
  {url:"coordination/descriptions_igdb_ps3_ps4_x360_xone_wiiu_switch.json", label:"descriptions PS3 PS4 Xbox Wii U Switch"},
  {url:"coordination/descriptions_igdb_modern_rare.json", label:"descriptions raretés consoles modernes"},
  {url:"coordination/descriptions_igdb_catalogue_principal_5062.json", label:"descriptions catalogue principal"},
  {url:"coordination/descriptions_volume_2_fixture.json", label:"descriptions volume 2"},
];
const PLAT_PRIORITY = [
  [/^Nintendo Switch 2$/,"switch2","Switch 2","nintendo"],
  [/^Nintendo Switch$/,"switch","Switch","nintendo"],
  [/^Switch$/,"switch","Switch","nintendo"],
  [/^PlayStation 5$/,"ps5","PlayStation 5","sony"],
  [/^PlayStation VR2$/,"psvr2","PS VR2","sony"],
  [/^PlayStation VR$/,"psvr","PS VR","sony"],
  [/^Xbox Series/,"xs","Xbox Series X/S","microsoft"],
  [/^S$/,"xs","Xbox Series X/S","microsoft"],
  [/^Xbox One/,"xone","Xbox One","microsoft"],
  [/^PlayStation 4$/,"ps4","PlayStation 4","sony"],
  [/^Wii U$/,"wiiu","Wii U","nintendo"],
  [/^Wii$/,"wii","Wii","nintendo"],
  [/^PlayStation 3$/,"ps3","PlayStation 3","sony"],
  [/^Xbox 360$/,"x360","Xbox 360","microsoft"],
  [/^PlayStation Vita$/,"vita","PS Vita","sony"],
  [/Nintendo 3DS/,"n3ds","Nintendo 3DS","nintendo"],
  [/Nintendo DSi?$/,"ds","Nintendo DS","nintendo"],
  [/GameCube/,"gc","GameCube","nintendo"],
  [/^Nintendo 64$/,"n64","Nintendo 64","nintendo"],
  [/^PlayStation 2$/,"ps2","PlayStation 2","sony"],
  [/^PlayStation$/,"ps1","PlayStation","sony"],
  [/^Dreamcast$/,"dc","Dreamcast","sega"],
  [/Saturn/,"saturn","Saturn","sega"],
  [/Mega Drive|Genesis/,"md","Mega Drive","sega"],
  [/Game Gear/,"gg","Game Gear","sega"],
  [/Master System/,"sms","Master System","sega"],
  [/Sega CD|^32X$|Sega 32X/,"segacd","Sega CD / 32X","sega"],
  [/Game Boy Advance/,"gba","Game Boy Advance","nintendo"],
  [/Game Boy Color/,"gbc","Game Boy Color","nintendo"],
  [/^Game Boy$/,"gb","Game Boy","nintendo"],
  [/Super Nintendo|Super Famicom|^Super NES/,"snes","Super Nintendo","nintendo"],
  [/^NES$|Nintendo Entertainment System|Family Computer(?! Disk)/,"nes","NES","nintendo"],
  [/Neo Geo/,"neogeo","Neo Geo","snk"],
  [/^Arcade$/,"arcade","Arcade","arcade"],
  [/Atari 2600/,"atari","Atari 2600","atari"],
  [/^Atari/,"atariother","Atari (autre)","atari"],
  [/PlayStation Portable|^PSP$/,"psp","PSP","sony"],
  [/3DO/,"3do","3DO","arcade"],
  [/Quest|PlayStation VR|Oculus|Windows Mixed Reality|SteamVR|visionOS|Daydream|Gear VR/,"vr","Réalité virtuelle","vr"],
  [/^iOS$|^Android$|Windows Phone|BlackBerry OS|Legacy Mobile Device|Windows Mobile/,"mobile","Mobile","mobile"],
  [/Web browser/,"web","Navigateur","web"],
  [/Stadia|OnLive/,"cloud","Cloud","cloud"],
  [/^Xbox$/,"xbox","Xbox","microsoft"],
  [/PC \(Microsoft Windows\)|PC \(Windows\)|^PC$|Steam \(PC\)|^DOS$|^Mac$|^macOS$|^Linux$/,"pc","PC","pc"],
];
const CATALOGUE_CACHE = "ludodex-catalogue-v1"; // vider via caches.delete(...) si les JSON sources changent
const KEY="ludodex-v1";
const START_COINS=500;
const REF_BASE=[10,25,60,150,400,1200];   // valeur de référence par rareté (pièces)
const FEE=0;                               // commission du marché sur les ventes (aucune)
const DISCARD_RATE=0.3;                    // défausse : 30 % de la valeur de référence
const W_MARKET=[30,28,22,12,6,2];          // rareté des cartes mises en vente par les autres joueurs
