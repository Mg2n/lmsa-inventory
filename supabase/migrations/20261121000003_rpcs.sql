-- =====================================================================
-- Views and RPCs used by the web app
-- =====================================================================

-- One row per product with stock, location totals and dashboard flags.
create or replace view public.v_products with (security_invoker = true) as
with s as (
  select itmcode, sum(qty_computed) as total_qty, sum(reserved_qty) as reserved_qty
  from public.erp_stock group by itmcode
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

-- Barcode data-quality issues: duplicates across items and odd-looking values.
create or replace view public.v_barcode_issues with (security_invoker = true) as
select 'duplicate'::text as issue, b.barcode_norm, b.barcode_raw, b.itmcode, b.unitcode
from public.erp_barcodes b
where b.barcode_norm in (
  select barcode_norm from public.erp_barcodes group by barcode_norm having count(distinct itmcode) > 1)
union all
select 'odd', b.barcode_norm, b.barcode_raw, b.itmcode, b.unitcode
from public.erp_barcodes b
where length(b.barcode_norm) > 20
   or b.barcode_raw is distinct from btrim(b.barcode_raw)
   or b.barcode_norm !~ '^[A-Z0-9./+-]+$';

grant select on public.v_barcode_issues to authenticated;

-- Product JSON used by lookup and by the location RPCs.
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
                     from public.erp_stock st where st.itmcode = p.itmcode) s on true
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

create or replace function public.last_sync()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'last_ok_at', (select max(finished_at) from public.sync_runs where status = 'ok'),
    'last_run', (select to_jsonb(r) from public.sync_runs r order by started_at desc limit 1))
  where private.is_staff()
$$;

-- Scan lookup. Returns every product matching the code (barcodes can be duplicated),
-- falling back to an exact item-code match.
create or replace function public.lookup_barcode(code text)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare
  v_norm text := private.norm_code(code);
  v_items text[];
  v_by text := 'barcode';
begin
  if v_norm is null then
    return jsonb_build_object('found', false, 'code_norm', null, 'products', '[]'::jsonb, 'last_sync', public.last_sync());
  end if;

  select array_agg(distinct itmcode) into v_items from public.erp_barcodes where barcode_norm = v_norm;
  if v_items is null then
    v_by := 'itmcode';
    select array_agg(distinct itmcode) into v_items from public.erp_products where upper(btrim(itmcode)) = v_norm;
  end if;

  return jsonb_build_object(
    'found', v_items is not null,
    'matched_by', case when v_items is not null then v_by end,
    'code_norm', v_norm,
    'products', coalesce((select jsonb_agg(private.product_json(i) order by i) from unnest(v_items) i), '[]'::jsonb),
    'last_sync', public.last_sync());
end $$;

-- Search by Arabic/English name, item code or barcode. Use with .range() + count.
create or replace function public.search_products(p_q text default null, p_filter text default null)
returns setof public.v_products language sql stable set search_path = ''
as $$
  select v.* from public.v_products v
  where (coalesce(btrim(p_q), '') = ''
         or private.ar_norm(v.name_ar) like '%' || private.ar_norm(btrim(p_q)) || '%'
         or lower(coalesce(v.name_en, '')) like '%' || lower(btrim(p_q)) || '%'
         or upper(v.itmcode) like '%' || upper(btrim(p_q)) || '%'
         or coalesce(v.barcodes, '') like '%' || coalesce(private.norm_code(p_q), '') || '%')
    and case p_filter
          when 'no_location'   then v.no_location and v.total_qty > 0
          when 'negative'      then v.negative_stock
          when 'below_reorder' then v.below_reorder
          when 'mismatch'      then v.mismatch
          else true end
  order by (upper(v.itmcode) = upper(btrim(coalesce(p_q, '')))) desc, v.name_ar, v.itmcode
$$;

-- Dashboard counters for the filter chips.
create or replace function public.product_counts()
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'all', count(*),
    'no_location', count(*) filter (where no_location and total_qty > 0),
    'negative', count(*) filter (where negative_stock),
    'below_reorder', count(*) filter (where below_reorder),
    'mismatch', count(*) filter (where mismatch))
  from public.v_products
$$;

-- ---------------------------------------------------------------------
-- Location changes (all logged to location_movements)
-- ---------------------------------------------------------------------
create or replace function private.require_staff_and_item(p_itmcode text)
returns void language plpgsql stable set search_path = ''
as $$
begin
  if not private.is_staff() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.erp_products where itmcode = p_itmcode) then
    raise exception 'unknown item %', p_itmcode using errcode = 'P0002';
  end if;
end $$;

-- Set the quantity of an item at a location (0 removes it).
create or replace function public.set_product_location(p_itmcode text, p_location_id uuid, p_qty numeric, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_before numeric;
begin
  perform private.require_staff_and_item(p_itmcode);
  if p_qty is null or p_qty < 0 then raise exception 'quantity must be >= 0' using errcode = '22023'; end if;
  if not exists (select 1 from public.locations where id = p_location_id) then
    raise exception 'unknown location' using errcode = 'P0002';
  end if;

  select qty into v_before from public.product_locations
   where itmcode = p_itmcode and location_id = p_location_id for update;

  if p_qty = 0 then
    delete from public.product_locations where itmcode = p_itmcode and location_id = p_location_id;
  else
    insert into public.product_locations (itmcode, location_id, qty, updated_by, updated_at)
    values (p_itmcode, p_location_id, p_qty, auth.uid(), now())
    on conflict (itmcode, location_id) do update
      set qty = excluded.qty, updated_by = excluded.updated_by, updated_at = now();
  end if;

  if v_before is distinct from p_qty and not (v_before is null and p_qty = 0) then
    insert into public.location_movements (itmcode, action, to_location_id, qty, qty_before, qty_after, reason, user_id)
    values (p_itmcode,
            case when p_qty = 0 then 'remove' when v_before is null then 'assign' else 'set' end,
            p_location_id, p_qty - coalesce(v_before, 0), coalesce(v_before, 0), p_qty, p_reason, auth.uid());
  end if;

  return private.product_json(p_itmcode);
end $$;

-- Add (or subtract) units at a location; used by "count mode" in setup.
create or replace function public.add_product_location(p_itmcode text, p_location_id uuid, p_delta numeric, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_before numeric;
begin
  perform private.require_staff_and_item(p_itmcode);
  select qty into v_before from public.product_locations
   where itmcode = p_itmcode and location_id = p_location_id for update;
  return public.set_product_location(p_itmcode, p_location_id, greatest(coalesce(v_before, 0) + p_delta, 0), p_reason);
end $$;

-- Move units between locations (p_qty null = move everything).
create or replace function public.move_product_location(p_itmcode text, p_from uuid, p_to uuid, p_qty numeric default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_from numeric; v_to numeric; v_qty numeric;
begin
  perform private.require_staff_and_item(p_itmcode);
  if p_from = p_to then raise exception 'source and target are the same' using errcode = '22023'; end if;
  if not exists (select 1 from public.locations where id = p_to) then
    raise exception 'unknown location' using errcode = 'P0002';
  end if;

  select qty into v_from from public.product_locations where itmcode = p_itmcode and location_id = p_from for update;
  if v_from is null then raise exception 'item is not at the source location' using errcode = 'P0002'; end if;
  v_qty := coalesce(p_qty, v_from);
  if v_qty <= 0 or v_qty > v_from then raise exception 'invalid quantity (max %)', v_from using errcode = '22023'; end if;
  select qty into v_to from public.product_locations where itmcode = p_itmcode and location_id = p_to for update;

  if v_qty = v_from then
    delete from public.product_locations where itmcode = p_itmcode and location_id = p_from;
  else
    update public.product_locations set qty = qty - v_qty, updated_by = auth.uid(), updated_at = now()
     where itmcode = p_itmcode and location_id = p_from;
  end if;

  insert into public.product_locations (itmcode, location_id, qty, updated_by, updated_at)
  values (p_itmcode, p_to, v_qty, auth.uid(), now())
  on conflict (itmcode, location_id) do update
    set qty = public.product_locations.qty + excluded.qty, updated_by = excluded.updated_by, updated_at = now();

  insert into public.location_movements (itmcode, action, from_location_id, to_location_id, qty, qty_before, qty_after, reason, user_id)
  values (p_itmcode, 'move', p_from, p_to, v_qty, coalesce(v_to, 0), coalesce(v_to, 0) + v_qty, p_reason, auth.uid());

  return private.product_json(p_itmcode);
end $$;

-- What is stored on a shelf.
create or replace function public.location_contents(p_location_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'itmcode', pl.itmcode, 'name_ar', p.name_ar, 'qty', pl.qty, 'updated_at', pl.updated_at)
           order by p.name_ar), '[]'::jsonb)
  from public.product_locations pl
  left join lateral (select name_ar from public.erp_products e where e.itmcode = pl.itmcode limit 1) p on true
  where pl.location_id = p_location_id
$$;

-- Admin: change a user's role (cannot remove the last admin).
create or replace function public.set_user_role(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_role not in ('admin', 'staff', 'pending') then raise exception 'bad role' using errcode = '22023'; end if;
  if p_role <> 'admin' and (select role from public.profiles where id = p_user_id) = 'admin'
     and (select count(*) from public.profiles where role = 'admin') <= 1 then
    raise exception 'cannot remove the last admin' using errcode = '22023';
  end if;
  update public.profiles set role = p_role where id = p_user_id;
end $$;

-- Function privileges: authenticated only.
revoke execute on function public.last_sync(), public.lookup_barcode(text), public.search_products(text, text),
  public.product_counts(), public.set_product_location(text, uuid, numeric, text),
  public.add_product_location(text, uuid, numeric, text),
  public.move_product_location(text, uuid, uuid, numeric, text), public.location_contents(uuid),
  public.set_user_role(uuid, text) from public, anon;
grant execute on function public.last_sync(), public.lookup_barcode(text), public.search_products(text, text),
  public.product_counts(), public.set_product_location(text, uuid, numeric, text),
  public.add_product_location(text, uuid, numeric, text),
  public.move_product_location(text, uuid, uuid, numeric, text), public.location_contents(uuid),
  public.set_user_role(uuid, text) to authenticated;
revoke execute on function private.require_staff_and_item(text) from public, anon;
grant execute on function private.require_staff_and_item(text) to authenticated;
