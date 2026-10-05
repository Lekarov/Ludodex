-- Ludodex Online — 001 : extensions et types énumérés
-- À exécuter en premier. Ne modifie aucune donnée existante (rien n'existe encore).

create extension if not exists pgcrypto;

do $$ begin
  create type profile_role as enum ('player', 'vip', 'moderator', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type market_party_type as enum ('bot', 'player');
exception when duplicate_object then null; end $$;

do $$ begin
  create type listing_type as enum ('sale', 'auction');
exception when duplicate_object then null; end $$;

do $$ begin
  create type listing_status as enum ('active', 'sold', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type report_status as enum ('pending', 'reviewed');
exception when duplicate_object then null; end $$;
