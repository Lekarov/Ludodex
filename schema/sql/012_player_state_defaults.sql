-- Ludodex Online — 012 : valeurs par défaut de player_state alignées sur le prototype
-- Deux écarts avec fresh() (site/js/persistence/save.js) corrigés avant qu'ils ne posent
-- problème sur de vrais comptes :
-- - boosters_available démarrait à 0 (003_player_state.sql), au lieu du stock plein (MAX_PACKS).
-- - coins démarrait à 0 (003_player_state.sql), au lieu de START_COINS (500).

alter table public.player_state
  alter column boosters_available set default 10,
  alter column coins set default 500;

-- Ne change pas les lignes déjà créées (ex. le compte de test) : mise à jour volontairement
-- laissée à vous si vous voulez aussi appliquer ces valeurs à un compte existant :
--   update public.player_state set boosters_available = 10, coins = 500
--     where profile_id = '<uuid du compte>';
