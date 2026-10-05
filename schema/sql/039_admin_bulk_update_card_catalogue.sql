-- Ludodex Online — 039 : mise à jour en masse de card_catalogue (colonnes de repli, admin only)
-- backfill_card_fields.js utilisait un upsert PostgREST classique (POST + Prefer:
-- resolution=merge-duplicates) : ça échoue avec "null value in column rarity violates not-null
-- constraint", parce que Postgres construit la ligne candidate pour ON CONFLICT DO UPDATE avant
-- de détecter le conflit, et exige donc les colonnes NOT NULL même si la ligne existe déjà et ne
-- sera jamais réellement insérée. Une vraie UPDATE (jamais d'INSERT) évite ce problème.
--
-- Restreint à trois colonnes de repli (whitelist), jamais accessible aux joueurs (pas de grant à
-- authenticated) : appelable uniquement avec la clé de service, qui bypasse les grants — c'est un
-- outil d'administration du catalogue, pas une action de jeu.

create or replace function public.admin_bulk_update_card_catalogue(p_column text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_column not in ('genres', 'description_en', 'description_fr') then
    raise exception 'Colonne non autorisée : %', p_column;
  end if;

  if p_column = 'genres' then
    update public.card_catalogue c set genres = r.value
      from jsonb_to_recordset(p_rows) as r(card_id text, value text)
      where c.card_id = r.card_id;
  elsif p_column = 'description_en' then
    update public.card_catalogue c set description_en = r.value
      from jsonb_to_recordset(p_rows) as r(card_id text, value text)
      where c.card_id = r.card_id;
  else
    update public.card_catalogue c set description_fr = r.value
      from jsonb_to_recordset(p_rows) as r(card_id text, value text)
      where c.card_id = r.card_id;
  end if;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.admin_bulk_update_card_catalogue(text, jsonb) from public, anon, authenticated;
