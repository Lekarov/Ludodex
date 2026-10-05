// Client Supabase partagé par toutes les pages. Nécessite config.js (URL + clé publique) chargé
// avant, et le SDK Supabase (CDN) chargé avant celui-ci.
const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
