// Met à jour des colonnes de card_catalogue pour des lignes qui existent DÉJÀ dans Supabase
// (contrairement aux imports CSV "ADD_..." qui n'ajoutent que des lignes nouvelles). Nécessaire
// pour remplir un champ ajouté après coup (genres, description_en, description_fr — voir
// 036_card_catalogue_descriptions.sql) sur les 200 000+ cartes déjà en base.
//
// Utilise la clé de service (bypass RLS, nécessaire pour écrire dans card_catalogue) — NE JAMAIS
// commiter cette clé ni la mettre dans le code du site. Fournie uniquement en variable
// d'environnement, à usage local ponctuel.
//
// Usage (PowerShell, depuis ce dossier) :
//   $env:SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co"
//   $env:SUPABASE_SERVICE_KEY = "sb_secret_..."
//   node backfill_card_fields.js genres
//   node backfill_card_fields.js description_en data/volumes/descriptions_en_2026/descriptions_en_2026.json
//   node backfill_card_fields.js description_fr data/volumes/descriptions_fr_2026/descriptions_fr_2026.json
//
// Premier argument : nom de colonne à remplir. "genres" est calculé depuis le catalogue consolidé
// (comme generate_card_catalogue.js). Pour description_en/description_fr, donner en 2e argument le
// chemin du fichier JSON {"igdb:<id>": "texte"} produit par outils_igdb/fetch_descriptions.py ou
// translate_descriptions.py (chemin relatif à la racine Ludodex).

const fs = require("fs");
const path = require("path");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;
if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("Définis SUPABASE_URL et SUPABASE_SERVICE_KEY (variables d'environnement) avant de lancer ce script.");
  process.exit(1);
}

const COLUMN = process.argv[2];
if (!["genres", "description_en", "description_fr"].includes(COLUMN)) {
  console.error("Usage : node backfill_card_fields.js <genres|description_en|description_fr> [fichier.json]");
  process.exit(1);
}

const ROOT = path.resolve(__dirname, "..", "..", "..");
const DATA_DIR = path.join(ROOT, "data");

// Même liste que generate_card_catalogue.js — tenue à jour manuellement en parallèle.
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
  "volumes/igdb_modern_2026/ludodex_igdb_modern_2026.json",
  "volumes/igdb_exhaustif_2026/ludodex_igdb_exhaustif_2026.json",
];

function buildUpdates() {
  if (COLUMN === "genres") {
    const merged = {};
    for (const rel of CATALOGUE_SOURCES) {
      const json = JSON.parse(fs.readFileSync(path.join(DATA_DIR, rel), "utf8"));
      Object.assign(merged, json);
    }
    const updates = [];
    for (const [id, e] of Object.entries(merged)) {
      if (e.genres && e.genres.length) {
        updates.push({ card_id: id, value: e.genres.join(", ") });
      }
    }
    return updates;
  }

  const jsonPath = process.argv[3];
  if (!jsonPath) {
    console.error(`Donne le chemin du fichier JSON de descriptions en 2e argument pour ${COLUMN}.`);
    process.exit(1);
  }
  const map = JSON.parse(fs.readFileSync(path.join(ROOT, jsonPath), "utf8"));
  return Object.entries(map)
    .filter(([, text]) => text && String(text).trim())
    .map(([id, text]) => ({ card_id: id, value: text }));
}

// Vraie UPDATE côté serveur (jamais d'INSERT) via 039_admin_bulk_update_card_catalogue.sql —
// un upsert PostgREST classique échoue ici : toutes les lignes existent déjà, mais Postgres
// exige quand même que la ligne candidate d'un ON CONFLICT DO UPDATE satisfasse les colonnes
// NOT NULL (ex. rarity) avant même de détecter le conflit.
async function upsertBatch(rows) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/admin_bulk_update_card_catalogue`, {
    method: "POST",
    headers: {
      "apikey": SERVICE_KEY,
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_column: COLUMN, p_rows: rows }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`HTTP ${res.status} : ${body.slice(0, 500)}`);
  }
}

async function main() {
  const updates = buildUpdates();
  console.log(`${updates.length} lignes à mettre à jour pour la colonne "${COLUMN}".`);
  const BATCH = 500;
  let done = 0;
  for (let i = 0; i < updates.length; i += BATCH) {
    const batch = updates.slice(i, i + BATCH);
    let attempt = 0;
    while (true) {
      try {
        await upsertBatch(batch);
        break;
      } catch (err) {
        attempt++;
        if (attempt > 5) throw err;
        console.warn(`Erreur (tentative ${attempt}/5) : ${err.message} — nouvelle tentative dans ${attempt}s`);
        await new Promise((r) => setTimeout(r, attempt * 1000));
      }
    }
    done += batch.length;
    process.stdout.write(`\r${done} / ${updates.length}`);
  }
  console.log(`\nTerminé : ${done} lignes mises à jour pour "${COLUMN}".`);
}

main().catch((err) => {
  console.error("\nÉchec :", err.message);
  process.exit(1);
});
