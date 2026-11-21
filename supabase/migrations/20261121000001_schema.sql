-- =====================================================================
-- Lmsa inventory scanner — core schema
-- erp_*  : read-only mirror of Spark Tech (written only by erp-ingest)
-- others : our own data (locations, profiles, audit, sync runs)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Pure helper functions
-- ---------------------------------------------------------------------

-- Barcode normalisation: remove all whitespace/control chars, upper-case.
create or replace function private.norm_code(p text)
returns text language sql immutable parallel safe set search_path = ''
as $$ select nullif(upper(regexp_replace(coalesce(p, ''), '[\s[:cntrl:]]+', '', 'g')), '') $$;

-- Safe numeric cast (returns null for garbage instead of failing a batch).
create or replace function private.num(p text)
returns numeric language sql immutable parallel safe set search_path = ''
as $$ select case when btrim(p) ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' then btrim(p)::numeric end $$;

-- Spark bit/char flags: 1/true/T/Y => true.
create or replace function private.truthy(p text)
returns boolean language sql immutable parallel safe set search_path = ''
as $$ select lower(btrim(coalesce(p, ''))) in ('1', 'true', 't', 'y', 'yes') $$;

-- Arabic-aware search normalisation (alef forms, ta marbuta, alef maqsura, tashkeel, tatweel).
create or replace function private.ar_norm(p text)
returns text language sql immutable parallel safe set search_path = ''
as $$
  select lower(
    translate(
      regexp_replace(coalesce(p, ''), '[ً-ْـ]', '', 'g'),
      'أإآٱةى', 'ااااهي'
    )
  )
$$;

-- ---------------------------------------------------------------------
-- Profiles (users & roles)
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text,
  full_name   text,
  role        text not null default 'pending' check (role in ('admin', 'staff', 'pending')),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Spark Tech mirror (read-only copies)
-- ---------------------------------------------------------------------
create table public.erp_warehouses (
  brnid        text not null,
  whsno        text not null,
  name         text,
  last_run_id  bigint,
  synced_at    timestamptz not null default now(),
  primary key (brnid, whsno)
);

create table public.erp_products (
  brnid          text not null,
  itmcode        text not null,
  name_ar        text,
  name_en        text,
  category       text,
  subcategory    text,
  item_group     text,
  sale_price     numeric,
  reorder_level  numeric,
  is_stopped     boolean not null default false,
  is_active      boolean not null default true,
  activate_raw   text,
  itmstop_raw    text,
  last_run_id    bigint,
  synced_at      timestamptz not null default now(),
  primary key (brnid, itmcode)
);
create index erp_products_itmcode_idx on public.erp_products (upper(itmcode));
create index erp_products_name_idx on public.erp_products (private.ar_norm(name_ar));

-- One row per ITMUNIT row. barcode_norm is indexed (not unique) because the
-- source contains duplicates; duplicates are surfaced in v_barcode_issues.
create table public.erp_barcodes (
  brnid         text not null,
  itmcode       text not null,
  unitcode      text not null,
  barcode_raw   text,
  barcode_norm  text not null,
  unit_name     text,
  unit_factor   numeric,
  unit_price    numeric,
  last_run_id   bigint,
  synced_at     timestamptz not null default now(),
  primary key (brnid, itmcode, unitcode)
);
create index erp_barcodes_norm_idx on public.erp_barcodes (barcode_norm);
create index erp_barcodes_item_idx on public.erp_barcodes (itmcode);

-- One row per ITEMSMASTER row (item x warehouse x batch).
create table public.erp_stock (
  brnid        text not null,
  itmcode      text not null,
  whsno        text not null,
  batchno      text not null default '',
  beginqty     numeric not null default 0,
  purchqty     numeric not null default 0,
  saleqty      numeric not null default 0,
  purchrtn     numeric not null default 0,
  salertn      numeric not null default 0,
  inqty        numeric not null default 0,
  outqty       numeric not null default 0,
  reserved_qty numeric not null default 0,
  qty_computed numeric generated always as
    (beginqty + purchqty - saleqty - purchrtn + salertn + inqty - outqty) stored,
  last_run_id  bigint,
  synced_at    timestamptz not null default now(),
  primary key (brnid, itmcode, whsno, batchno)
);
create index erp_stock_item_idx on public.erp_stock (itmcode);

-- Copy of ITMSALES lines (table ready; copying is a v1 TODO).
create table public.erp_sales (
  brnid       text not null,
  whsno       text not null,
  gltype      text not null,
  vouno       text not null,
  itmcode     text not null,
  line_serial text not null,
  saleqty     numeric,
  ufact       numeric,
  unitprice   numeric,
  shiftid     text,
  posno       text,
  synced_at   timestamptz not null default now(),
  primary key (brnid, whsno, gltype, vouno, itmcode, line_serial)
);

-- ---------------------------------------------------------------------
-- Our data: storage locations
-- ---------------------------------------------------------------------
create table public.locations (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code = upper(btrim(code)) and code <> ''),
  zone        text,
  aisle       text,
  shelf       text,
  bin         text,
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.product_locations (
  id          uuid primary key default gen_random_uuid(),
  itmcode     text not null,
  location_id uuid not null references public.locations (id) on delete restrict,
  qty         numeric not null default 0 check (qty >= 0),
  updated_by  uuid references auth.users (id) on delete set null,
  updated_at  timestamptz not null default now(),
  unique (itmcode, location_id)
);
create index product_locations_loc_idx on public.product_locations (location_id);

create table public.location_movements (
  id               bigint generated always as identity primary key,
  itmcode          text not null,
  action           text not null check (action in ('assign', 'add', 'set', 'move', 'remove')),
  from_location_id uuid references public.locations (id) on delete set null,
  to_location_id   uuid references public.locations (id) on delete set null,
  qty              numeric,
  qty_before       numeric,
  qty_after        numeric,
  reason           text,
  user_id          uuid references auth.users (id) on delete set null,
  created_at       timestamptz not null default now()
);
create index location_movements_item_idx on public.location_movements (itmcode, created_at desc);

-- ---------------------------------------------------------------------
-- Sync bookkeeping
-- ---------------------------------------------------------------------
create table public.sync_runs (
  id             bigint generated always as identity primary key,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  status         text not null default 'running' check (status in ('running', 'ok', 'error', 'abandoned')),
  full_sync      boolean not null default false,
  agent_version  text,
  host           text,
  rows_read      jsonb not null default '{}'::jsonb,
  rows_upserted  jsonb not null default '{}'::jsonb,
  rows_deleted   jsonb not null default '{}'::jsonb,
  duration_ms    integer,
  error_message  text
);
create index sync_runs_started_idx on public.sync_runs (started_at desc);

-- Shared secret for the sync agent (only a SHA-256 hash is stored).
create table private.sync_config (
  id           int primary key default 1 check (id = 1),
  secret_hash  text not null,
  updated_at   timestamptz not null default now()
);
revoke all on private.sync_config from public, anon, authenticated;
