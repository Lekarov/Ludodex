-- Ludodex Online — 067 : permet de dézoomer sous 1× dans l'éditeur de catalogue (retour Doktor
-- 29/09/2026 : "on peut pas dézoomer moins ?") — la contrainte de 066 plafonnait le zoom entre
-- 1.00 et 3.00, empêchant de rétrécir une image trop zoomée à la source. Nouvelle plage : 0.50 à
-- 3.00. Le défaut (1.00, rendu identique à avant 066) ne change pas.
alter table public.card_catalogue drop constraint if exists card_catalogue_image_scale_check;
alter table public.card_catalogue add constraint card_catalogue_image_scale_check check (image_scale between 0.50 and 3.00);
