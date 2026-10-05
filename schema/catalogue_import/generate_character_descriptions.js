// Génère une courte présentation française pour chaque personnage du catalogue.
// Le texte est composé localement et de façon déterministe à partir des métadonnées existantes :
// aucun appel réseau ou modèle n'est nécessaire.
//
// Usage : node generate_character_descriptions.js

const fs = require("fs");
const path = require("path");

const INPUT = path.join(__dirname, "character_catalogue.csv");
const OUTPUT = path.join(__dirname, "character_catalogue_descriptions.json");

function parseCsv(text) {
  const rows = [];
  let row = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field.replace(/\r$/, "")); rows.push(row); row = []; field = ""; }
    else field += c;
  }
  if (field || row.length) { row.push(field.replace(/\r$/, "")); rows.push(row); }
  const headers = rows.shift();
  return rows.filter((r) => r.some(Boolean)).map((values) =>
    Object.fromEntries(headers.map((header, i) => [header, values[i] || ""])),
  );
}

function hash32(value) {
  let h = 2166136261;
  for (const c of value) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

function pick(row, choices, salt = "") {
  return choices[hash32(row.character_id + salt) % choices.length];
}

const SPECIES = {
  Bird: "oiseau", Squirrel: "écureuil", "Bear cub": "ourson", Cub: "ourson", Bear: "ours",
  Cat: "chat", Dog: "chien", Duck: "canard", Frog: "grenouille", Rabbit: "lapin", Wolf: "loup",
  Elephant: "éléphant", Mouse: "souris", Pig: "cochon", Sheep: "mouton", Horse: "cheval",
  Alligator: "alligator", Anteater: "tamanoir", Chicken: "poule", Cow: "vache", Deer: "cerf",
  Eagle: "aigle", Gorilla: "gorille", Hamster: "hamster", Hippo: "hippopotame", Koala: "koala",
  Kangaroo: "kangourou", Lion: "lion", Monkey: "singe", Octopus: "pieuvre", Ostrich: "autruche",
  Owl: "hibou", Penguin: "manchot", Rhino: "rhinocéros", Rooster: "coq", Tiger: "tigre",
  Goat: "chèvre", Beaver: "castor", Pigeon: "pigeon", Tortoise: "tortue", Alpaca: "alpaga",
  Boar: "sanglier", Peacock: "paon", Warrior: "guerrier", Machine: "machine", DRAGON: "dragon",
  Dragon: "dragon", Fiend: "démon", BEAST: "bête", Beast: "bête", Spellcaster: "magicien",
  Fairy: "fée", Fighter: "combattant", Mage: "mage", Marksman: "tireur", UNDEAD: "mort-vivant",
  Undead: "mort-vivant", "Winged Beast": "bête ailée", Cyberse: "cyberse", Aqua: "créature aquatique",
  Rock: "créature de roche", Zombie: "zombie", Insect: "insecte", "Beast-Warrior": "bête-guerrier",
  ELEMENTAL: "élémentaire", Elemental: "élémentaire", Plant: "plante", MECHANICAL: "mécanique",
  Psychic: "psychique", Reptile: "reptile", DEMON: "démon", Dinosaur: "dinosaure", Fish: "poisson",
  Pyro: "Pyro", Thunder: "créature de tonnerre", Carry: "combattant offensif", Initiator: "initiateur",
  Support: "soutien", Assassin: "assassin", Tank: "tank", shielder: "Shielder", saber: "Saber",
  archer: "Archer", lancer: "Lancer", rider: "Rider", caster: "Caster", assassin: "Assassin",
  berserker: "Berserker", ruler: "Ruler", avenger: "Avenger", alterego: "Alter Ego",
  moonCancer: "Moon Cancer", foreigner: "Foreigner", pretender: "Pretender",
};

const PERSONALITY = {
  Jock: "au tempérament sportif et plein d'entrain", Normal: "au naturel doux et attentionné",
  Lazy: "au tempérament décontracté et rêveur", Snooty: "au goût raffiné, avec un brin de hauteur",
  Peppy: "à l'enthousiasme communicatif", Cranky: "au caractère bourru mais attachant",
  Smug: "à l'assurance pleine de charme", "Big sister": "au naturel franc et protecteur",
};

const ROLE = {
  Fighter: "combattant", Mage: "mage", Marksman: "tireur", Support: "soutien", Assassin: "assassin",
  Tank: "tank", Carry: "carry", Initiator: "initiateur", Initiateur: "initiateur", Contrôleur: "contrôleur",
  Duelliste: "duelliste", Sentinelle: "sentinelle", nuker: "spécialiste des dégâts magiques",
  disabler: "spécialiste du contrôle", escape: "expert de la mobilité", durable: "combattant robuste",
  pusher: "spécialiste de la poussée", jungler: "combattant de la jungle",
};

function frenchRole(raw) {
  if (!raw) return "";
  return ROLE[raw] || ROLE[raw.toLowerCase()] || SPECIES[raw] || "";
}

function frenchSpecies(raw) {
  if (!raw) return "";
  return SPECIES[raw] || (/^[A-ZÀ-ÖØ-Þ -]+$/.test(raw) ? SPECIES[raw.toUpperCase()] : "") || "";
}

function frenchTypeLine(raw) {
  if (!raw) return "";
  if (/^Legendary Creature\s*[—-]/i.test(raw)) return "créature légendaire";
  if (/^Creature\s*[—-]/i.test(raw)) return "créature";
  if (/^Legendary Planeswalker\s*[—-]/i.test(raw)) return "planeswalker légendaire";
  if (/^Planeswalker\s*[—-]/i.test(raw)) return "planeswalker";
  return "";
}

function withArticle(noun) {
  const feminine = new Set([
    "machine", "bête", "fée", "créature aquatique", "créature de roche", "plante", "poule",
    "souris", "grenouille", "chèvre", "pieuvre", "autruche", "tortue",
  ]);
  return `${feminine.has(noun) ? "une" : "un"} ${noun}`;
}

function quoteIdea(raw) {
  const q = (raw || "").trim();
  if (!q) return "";
  // Les libellés déjà français (titres, devises courtes) peuvent être repris ; les textes anglais
  // sont seulement adaptés par idée, jamais recopiés.
  if (/[àâçéèêëîïôùûüœ]|\b(de|des|du|la|le|les|une|un|et|pour|sans|sur|dans|mon|ma|aux)\b/i.test(q)
      && q.length <= 65) return q.replace(/[.!]+$/, "");
  const lower = q.toLowerCase();
  const ideas = [
    [/never give up|quitters|don't give up/, "On n'abandonne jamais"],
    [/love|heart/, "Le cœur montre la voie"],
    [/dream/, "Il faut poursuivre ses rêves"],
    [/friend/, "L'amitié fait toute la différence"],
    [/strong|strength|power/, "La force se forge chaque jour"],
    [/fight|battle|victory|win/, "Chaque combat mérite d'être mené"],
    [/fast|speed|pedal|hurry/, "Toujours plus vite, toujours plus loin"],
    [/life|live/, "Chaque journée compte"],
    [/happy|smile|laugh/, "Un sourire change toute une journée"],
    [/food|eat|snack|hungry/, "Un bon repas remet toujours d'aplomb"],
    [/magic|spell/, "La magie récompense les esprits audacieux"],
    [/agi\b/, "L'agilité ouvre toutes les voies"],
    [/str\b/, "La puissance décide du rythme"],
  ];
  return (ideas.find(([re]) => re.test(lower)) || [null, ""])[1];
}

function gameOrigin(row) {
  if (!row.games) return row.franchise;
  const first = row.games.split(",")[0].trim();
  return first || row.franchise;
}

function compose(row) {
  const name = row.name.trim();
  const origin = gameOrigin(row);
  const variant = hash32(row.character_id) % 12;
  let text;

  if (row.franchise === "Animal Crossing") {
    const species = frenchSpecies(row.species) || "habitant";
    const nature = PERSONALITY[row.personality] || "au caractère bien trempé";
    const idea = quoteIdea(row.quote);
    const tails = [
      "Sa présence apporte une touche unique à la vie du village.",
      "On le reconnaît vite à son tempérament et à sa façon bien à lui d'animer le voisinage.",
      "Une rencontre chaleureuse pour tous ceux qui aiment bâtir un village vivant.",
      "Au fil des jours, sa personnalité donne du relief aux petites histoires du village.",
    ];
    text = variant % 3 === 0 && idea
      ? `${name}, ${species} ${nature} d'Animal Crossing, suit volontiers cette devise : « ${idea}. »`
      : `${name} est ${withArticle(species)} ${nature}, que l'on rencontre dans ${origin}. ${pick(row, tails, "ac")}`;
  } else if (row.franchise === "Pokémon") {
    const form = { legendary: "Pokémon légendaire", mythical: "Pokémon fabuleux", mega: "Méga-Pokémon", regional: "forme régionale", gmax: "forme Gigamax" }[row.character_type] || "Pokémon";
    const tails = ["Il enrichit chaque équipe par son identité et son style de combat.", "Sa silhouette et ses aptitudes en font une rencontre mémorable pour les Dresseurs.", "Il trouve naturellement sa place dans les aventures des Dresseurs.", "Une créature à découvrir, entraîner et faire progresser au fil des combats."];
    text = `${name} est ${form === "forme régionale" || form === "forme Gigamax" ? "une " : "un "}${form} apparu avec la ${row.games || "série Pokémon"}. ${pick(row, tails, "pk")}`;
  } else if (row.franchise === "League of Legends") {
    const role = frenchRole(row.species) || "champion";
    const skin = row.character_type === "skin" ? "une apparence alternative d'un" : "un";
    const title = quoteIdea(row.quote);
    const tails = ["Sur la Faille, son style donne un visage singulier à chaque affrontement.", "Son identité marque autant la Faille que les stratégies bâties autour de lui.", "Une présence reconnaissable qui renouvelle l'allure des combats de Runeterra."];
    text = `${name} incarne ${skin} ${role} de League of Legends${title ? `, connu comme « ${title} »` : ""}. ${pick(row, tails, "lol")}`;
  } else if (row.franchise === "Magic: The Gathering") {
    const type = frenchTypeLine(row.quote);
    const kind = row.character_type === "legendary" ? "figure légendaire" : row.character_type === "mythical" ? "figure mythique" : "créature";
    const tails = ["Sur le champ de bataille, cette carte ouvre de nouvelles lignes de jeu.", "Son identité nourrit les stratégies et les récits du Multivers.", "Une présence qui donne du caractère aux affrontements entre planeswalkers.", "Sa place dans un deck dépend autant de ses synergies que du plan de jeu choisi."];
    text = `${name} est ${type.startsWith("planeswalker") ? "un" : "une"} ${type || kind} de Magic: The Gathering. ${pick(row, tails, "mtg")}`;
  } else if (row.franchise === "Yu-Gi-Oh!") {
    const species = frenchSpecies(row.species) || "monstre";
    const attribute = { EARTH: "Terre", WATER: "Eau", WIND: "Vent", FIRE: "Feu", LIGHT: "Lumière", DARK: "Ténèbres", DIVINE: "Divin" }[row.quote];
    const tails = ["Il peut devenir une pièce décisive lorsque ses synergies sont bien exploitées.", "Son invocation apporte une identité forte aux duels et aux combinaisons de cartes.", "À chaque duel, sa place dépend du rythme et des synergies du deck.", "Une carte à intégrer avec soin pour tirer parti de son potentiel sur le Terrain."];
    text = `${name} est ${withArticle(species)} de Yu-Gi-Oh!${attribute ? ` associé à l'attribut ${attribute}` : ""}. ${pick(row, tails, "ygo")}`;
  } else if (row.franchise === "Hearthstone") {
    const tribe = frenchSpecies(row.species);
    const heroClass = { MAGE: "mage", WARRIOR: "guerrier", HUNTER: "chasseur", PRIEST: "prêtre", ROGUE: "voleur", SHAMAN: "chamane", WARLOCK: "démoniste", PALADIN: "paladin", DRUID: "druide", DEMONHUNTER: "chasseur de démons", DEATHKNIGHT: "chevalier de la mort" }[row.quote];
    const tails = ["Bien joué, il contribue à renverser le cours d'une partie.", "Ses synergies peuvent donner une direction inattendue à un deck.", "Sur le plateau, sa valeur dépend du moment choisi pour le déployer.", "Une carte dont le potentiel se révèle au cœur des bonnes combinaisons."];
    text = `${name} est ${tribe ? withArticle(tribe) : "un personnage"} de Hearthstone${heroClass ? ` lié à la classe ${heroClass}` : ""}. ${pick(row, tails, "hs")}`;
  } else if (row.franchise === "Dota 2") {
    const role = frenchRole(row.species) || "héros";
    const tails = ["Ses décisions peuvent faire basculer un affrontement d'équipe.", "Son efficacité repose sur le placement, le rythme et la coordination.", "Entre escarmouches et combats d'équipe, son rôle façonne la partie."];
    text = `${name} est un ${role} de Dota 2, pensé pour peser sur le champ de bataille. ${pick(row, tails, "dota")}`;
  } else if (row.franchise === "Valorant") {
    const role = frenchRole(row.species) || "agent";
    const tails = ["Ses compétences prennent tout leur sens au sein d'une équipe coordonnée.", "Son arsenal tactique permet d'imprimer un rythme particulier à chaque manche.", "Bien maîtrisé, il crée des ouvertures et transforme le déroulement d'une manche."];
    text = `${name} est un ${role} de VALORANT, doté d'une identité tactique bien marquée. ${pick(row, tails, "val")}`;
  } else if (row.franchise === "Genshin Impact") {
    const region = row.species && !/^[A-Z]+$/.test(row.species) ? row.species : "Teyvat";
    const title = quoteIdea(row.quote);
    const tails = ["Son parcours et ses talents enrichissent les aventures du Voyageur.", "Ses aptitudes lui donnent une place singulière au sein d'une équipe.", "Une rencontre marquante au fil de l'exploration et des récits de Teyvat."];
    text = `${name} est une figure de ${region} dans Genshin Impact${title ? `, présentée comme « ${title} »` : ""}. ${pick(row, tails, "gi")}`;
  } else if (row.franchise === "Honkai: Star Rail") {
    const tails = ["Son histoire accompagne l'équipage au fil d'un voyage entre les mondes.", "Ses talents et son parcours donnent une couleur unique aux expéditions stellaires.", "Une personnalité à découvrir au fil des étapes du périple astral."];
    text = `${name} fait partie des personnages de Honkai: Star Rail. ${pick(row, tails, "hsr")}`;
  } else if (row.franchise === "Fortnite") {
    const rarity = { gaminglegends: "Légendes du jeu vidéo", marvel: "Marvel", dc: "DC", starwars: "Star Wars", icon: "Série Icônes", epic: "épique", legendary: "légendaire", rare: "rare", uncommon: "atypique" }[row.quote];
    const tails = ["Cette tenue permet d'affirmer un style immédiatement reconnaissable sur l'île.", "Son apparence donne une signature visuelle forte à chaque partie.", "Un look conçu pour se démarquer, du salon jusqu'aux derniers duels.", "Cette silhouette rejoint la vaste galerie de héros et d'invités du jeu."];
    text = `${name} est une tenue de Fortnite${rarity ? ` classée ${rarity}` : ""}. ${pick(row, tails, "fn")}`;
  } else if (row.franchise === "Digimon") {
    const tails = ["Son évolution peut ouvrir la voie à de nouvelles formes et aptitudes.", "Il appartient à un monde numérique où chaque évolution transforme son potentiel.", "Partenaire ou adversaire, il enrichit la grande diversité du Monde Digital.", "Ses capacités se développent au fil des combats et des digivolutions."];
    text = `${name} est un Digimon issu du Monde Digital. ${pick(row, tails, "digi")}`;
  } else if (row.franchise === "Fate/Grand Order") {
    const role = frenchRole(row.species) || "Servant";
    const rank = row.character_type === "legendary" ? " particulièrement rare" : row.character_type === "mythical" ? " d'exception" : "";
    const tails = ["Ses pouvoirs peuvent changer l'issue d'une bataille pour le Saint Graal.", "Son histoire et ses aptitudes en font un allié singulier du Maître.", "Son Noble Phantasm et son parcours nourrissent les récits de la Chaldée."];
    text = `${name} est un Servant de classe ${role}${rank} dans Fate/Grand Order. ${pick(row, tails, "fgo")}`;
  } else if (row.franchise === "Nintendo (Amiibo)") {
    const series = row.species || "l'univers Nintendo";
    const tails = ["Sa figurine amiibo prolonge sa présence au-delà de l'écran.", "Cette incarnation amiibo célèbre une silhouette familière du jeu vidéo.", "Une figure emblématique à retrouver sous la forme d'un amiibo à collectionner."];
    text = `${name} est un personnage de ${series}, célébré dans la collection Nintendo amiibo. ${pick(row, tails, "amiibo")}`;
  } else if (row.franchise === "Overwatch") {
    const role = { tank: "tank", damage: "héros de dégâts", support: "soutien" }[row.species] || "héros";
    const tails = ["Sur le champ de bataille, son style impose son propre rythme aux affrontements en équipe.", "Sa maîtrise demande de la coordination pour révéler tout son potentiel.", "Une présence reconnaissable qui façonne la composition d'équipe.", "Chaque rencontre sur la carte peut basculer selon la façon dont il est joué."];
    text = `${name} est un ${role} d'Overwatch. ${pick(row, tails, "ow")}`;
  } else if (row.franchise === "Warframe") {
    const isPrime = row.character_type === "legendary";
    const kind = isPrime ? "la variante Prime" : "un exosuit";
    const tails = ["Ses capacités définissent un style de combat bien à lui sur le terrain.", "Son arsenal de pouvoirs ouvre des approches tactiques variées pour les Tenno.", "Une signature de combat que l'on apprend à maîtriser avec le temps.", "Son potentiel se révèle pleinement une fois sa configuration de mods affinée."];
    text = `${name} est ${kind} de Warframe${isPrime ? ", plus rare et aux statistiques affinées," : ""}, porté au combat par les Tenno. ${pick(row, tails, "wf")}`;
  } else if (row.franchise === "Dofus") {
    const family = row.species || "bestiaire";
    const levelMatch = /Niveau (\d+)(?:-(\d+))?/.exec(row.quote || "");
    const levelText = levelMatch
      ? (levelMatch[2] && levelMatch[2] !== levelMatch[1]
          ? `du niveau ${levelMatch[1]} au niveau ${levelMatch[2]}`
          : `de niveau ${levelMatch[1]}`)
      : "";
    const kind = row.character_type === "boss" ? "boss redouté"
      : row.character_type === "miniboss" ? "mini-boss coriace"
      : "monstre";
    const tails = [
      "Un adversaire qui marque la mémoire des aventuriers du Monde des Douze.",
      "Sa rencontre demande de bien lire ses résistances avant de s'engager au combat.",
      "Un habitué des donjons et zones de chasse, connu des joueurs aguerris.",
      "Son butin attire régulièrement les chasseurs de ressources et de sets.",
    ];
    text = `${name} est un ${kind} de la famille des ${family}${levelText ? `, rencontré ${levelText}` : ""} dans Dofus. ${pick(row, tails, "dofus")}`;
  } else {
    text = `${name} est un personnage de ${row.franchise}. Son identité et son parcours lui donnent une place singulière dans cet univers.`;
  }

  text = text.replace(/\s+/g, " ").replace(/\s+([,.])/g, "$1").trim();
  if (text.length < 100) text += " Une présence mémorable à découvrir dans son univers d'origine.";
  if (text.length > 220) text = text.slice(0, 217).replace(/\s+\S*$/, "") + "…";
  return text;
}

function main() {
  const rows = parseCsv(fs.readFileSync(INPUT, "utf8").replace(/^\uFEFF/, ""));
  const output = {};
  for (const row of rows) {
    if (!row.character_id) throw new Error("Ligne sans character_id détectée.");
    if (Object.hasOwn(output, row.character_id)) throw new Error(`character_id dupliqué : ${row.character_id}`);
    const description = compose(row);
    if (!description) throw new Error(`Description vide pour ${row.character_id}`);
    output[row.character_id] = description;
  }
  fs.writeFileSync(OUTPUT, JSON.stringify(output, null, 2) + "\n", "utf8");
  console.log(`${Object.keys(output).length} descriptions écrites dans ${path.relative(process.cwd(), OUTPUT)}.`);
}

main();
