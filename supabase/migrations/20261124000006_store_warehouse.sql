-- =====================================================================
-- Count only this store's warehouse(s) in stock totals (decided 2026-11-24).
-- Spark Tech's ITEMSMASTER holds every item in 6 warehouses; the store is
-- warehouse 3 "فرع عريجا" (the only row in its WAREHOUSES table), and the
-- owner confirmed item 001 should show 16 (warehouse 3), not 48 (all six).
-- All warehouses are still synced; only the totals are filtered.
-- =====================================================================

create table public.stock_warehouses (
  brnid      text not null,
  whsno      text not null,
  note       text,
  created_at timestamptz not null default now(),
  primary key (brnid, whsno)
);
comment on table public.stock_warehouses is
  'Warehouses whose stock counts in the app''s quantities. Empty = count all warehouses.';

alter table public.stock_warehouses enable row level security;
create policy stock_warehouses_read  on public.stock_warehouses for select to authenticated using ((select private.is_staff()));
create policy stock_warehouses_admin on public.stock_warehouses for all    to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
revoke all on public.stock_warehouses from anon;
grant select, insert, update, delete on public.stock_warehouses to authenticated;

insert into public.stock_warehouses (brnid, whsno, note) values ('1', '3', 'فرع عريجا');

-- Stock rows that count (all of them if no warehouse is configured).
create or replace view public.v_store_stock with (security_invoker = true) as
select s.*
from public.erp_stock s
where not exists (select 1 from public.stock_warehouses)
   or exists (select 1 from public.stock_warehouses w where w.brnid = s.brnid and w.whsno = s.whsno);

grant select on public.v_store_stock to authenticated;

create or replace view public.v_products with (security_invoker = true) as
with s as (
  select itmcode, sum(qty_computed) as total_qty, sum(reserved_qty) as reserved_qty
  from public.v_store_stock group by itmcode
), l as (
  select pl.itmcode, sum(pl.qty) as located_qty, count(*) as location_count,
         string_agg(loc.code || ':' || trim_scale(pl.qty)::text, ' ' order by loc.code) as location_codes
  from public.product_locations pl join public.locations loc on loc.id = pl.location_id
  group by pl.itmcode
), b as (
  select itmcode, min(barcode_norm) as barcode, string_agg(barcode_norm, ' ') as barcodes
  from public.erp_barcodes group by itmcode
)
select p.brnid, p.itmcode, p.name_ar, p.name_en, p.category, p.subcategory, p.item_group,
       p.sale_price, p.reorder_level, p.is_active, p.is_stopped, p.synced_at,
       coalesce(s.total_qty, 0)      as total_qty,
       coalesce(s.reserved_qty, 0)   as reserved_qty,
       coalesce(l.located_qty, 0)    as located_qty,
       coalesce(l.location_count, 0) as location_count,
       l.location_codes,
       b.barcode, b.barcodes,
       (coalesce(l.location_count, 0) = 0)                                         as no_location,
       (coalesce(s.total_qty, 0) < 0)                                              as negative_stock,
       (coalesce(p.reorder_level, 0) > 0 and coalesce(s.total_qty, 0) < p.reorder_level) as below_reorder,
       (coalesce(l.location_count, 0) > 0 and coalesce(l.located_qty, 0) <> coalesce(s.total_qty, 0)) as mismatch
from public.erp_products p
left join s on s.itmcode = p.itmcode
left join l on l.itmcode = p.itmcode
left join b on b.itmcode = p.itmcode;

grant select on public.v_products to authenticated;

create or replace function private.product_json(p_itmcode text)
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'brnid', p.brnid, 'itmcode', p.itmcode, 'name_ar', p.name_ar, 'name_en', p.name_en,
    'category', p.category, 'subcategory', p.subcategory,
    'sale_price', p.sale_price, 'reorder_level', p.reorder_level,
    'is_active', p.is_active, 'is_stopped', p.is_stopped,
    'total_qty', coalesce(s.total_qty, 0), 'reserved_qty', coalesce(s.reserved_qty, 0),
    'located_qty', coalesce(l.located_qty, 0),
    'locations', coalesce(l.items, '[]'::jsonb),
    'barcodes', coalesce((select jsonb_agg(jsonb_build_object('barcode', b.barcode_norm, 'unit_name', b.unit_name,
                          'unit_factor', b.unit_factor, 'unit_price', b.unit_price) order by b.unitcode)
                          from public.erp_barcodes b where b.itmcode = p.itmcode), '[]'::jsonb),
    'negative_stock', coalesce(s.total_qty, 0) < 0,
    'mismatch', coalesce(l.cnt, 0) > 0 and coalesce(l.located_qty, 0) <> coalesce(s.total_qty, 0),
    'synced_at', p.synced_at)
  from public.erp_products p
  left join lateral (select sum(qty_computed) total_qty, sum(reserved_qty) reserved_qty
                     from public.v_store_stock st where st.itmcode = p.itmcode) s on true
  left join lateral (select sum(pl.qty) located_qty, count(*) cnt,
                            jsonb_agg(jsonb_build_object('location_id', loc.id, 'code', loc.code,
                                      'description', loc.description, 'qty', pl.qty,
                                      'updated_at', pl.updated_at) order by loc.code) items
                     from public.product_locations pl join public.locations loc on loc.id = pl.location_id
                     where pl.itmcode = p.itmcode) l on true
  where p.itmcode = p_itmcode
  order by p.brnid
  limit 1
$$;
grant execute on function private.product_json(text) to authenticated;
