// Met à jour description_fr sur les lignes DÉJÀ présentes dans public.character_catalogue.
// Ce script n'insère aucune ligne et ne modifie aucune autre colonne.
//
// Usage (PowerShell, depuis la racine du projet) :
//   $env:SUPABASE_URL = "https://<projet>.supabase.co"
//   $env:SUPABASE_SERVICE_KEY = "sb_secret_..."
//   node schema/catalogue_import/backfill_character_description.js

const fs = require("fs");
const path = require("path");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;
if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("Définis SUPABASE_URL et SUPABASE_SERVICE_KEY avant de lancer ce script.");
  process.exit(1);
}

const JSON_PATH = path.join(__dirname, "character_catalogue_descriptions.json");

function buildUpdates() {
  const map = JSON.parse(fs.readFileSync(JSON_PATH, "utf8"));
  return Object.entries(map)
    .filter(([, text]) => text && String(text).trim())
    .map(([characterId, text]) => ({ characterId, description: String(text).trim() }));
}

async function updateOne({ characterId, description }) {
  const query = new URLSearchParams({ character_id: `eq.${characterId}` });
  const res = await fetch(`${SUPABASE_URL}/rest/v1/character_catalogue?${query}`, {
    method: "PATCH",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({ description_fr: description }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`HTTP ${res.status} pour ${characterId} : ${body.slice(0, 500)}`);
  }
}

async function withRetry(update) {
  for (let attempt = 1; ; attempt++) {
    try { await updateOne(update); return; }
    catch (err) {
      if (attempt >= 5) throw err;
      console.warn(`Erreur (tentative ${attempt}/5) : ${err.message}`);
      await new Promise((resolve) => setTimeout(resolve, attempt * 1000));
    }
  }
}

async function main() {
  const updates = buildUpdates();
  console.log(`${updates.length} lignes à mettre à jour dans character_catalogue.description_fr.`);
  const CONCURRENCY = 12;
  let cursor = 0, done = 0;
  async function worker() {
    while (true) {
      const index = cursor++;
      if (index >= updates.length) return;
      await withRetry(updates[index]);
      done++;
      if (done % 100 === 0 || done === updates.length) process.stdout.write(`\r${done} / ${updates.length}`);
    }
  }
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  console.log(`\nTerminé : ${done} descriptions mises à jour.`);
}

main().catch((err) => {
  console.error("\nÉchec :", err.message);
  process.exit(1);
});
