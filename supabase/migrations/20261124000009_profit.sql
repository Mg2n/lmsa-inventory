-- =====================================================================
-- Profit (decided 2026-11-24, admin only): cost of goods from Spark Tech
-- (GLVOUHEAD.INVCOSTAMT, ITMSALES.TOTALCOST). Profit = revenue before tax
-- - cost; returns subtract. Null when cost has not been synced yet (the
-- agent only reads cost once SQL Server grants those two columns).
-- =====================================================================
alter table public.erp_sales_heads add column if not exists invcostamt numeric;
alter table public.erp_sales_lines add column if not exists totalcost numeric;

create or replace function private.ingest_batch(p_run bigint, p_table text, p_rows jsonb, p_deletes jsonb)
returns jsonb language plpgsql set search_path = ''
as $$
declare
  v_up int := 0; v_del int := 0; v_skipped int := 0;
begin
  p_rows := coalesce(p_rows, '[]'::jsonb);
  p_deletes := coalesce(p_deletes, '[]'::jsonb);

  if p_table = 'products' then
    insert into public.erp_products as t (brnid, itmcode, name_ar, name_en, category, subcategory, item_group,
                                          sale_price, reorder_level, is_stopped, is_active, activate_raw, itmstop_raw,
                                          last_run_id, synced_at)
    select distinct on (btrim(r->>'BRNID'), btrim(r->>'ITMCODE'))
           btrim(r->>'BRNID'), btrim(r->>'ITMCODE'), nullif(btrim(r->>'ITMDESC'), ''), nullif(btrim(r->>'ITMLATIN'), ''),
           nullif(btrim(r->>'ITMCAT'), ''), nullif(btrim(r->>'ITMSUBCAT'), ''), nullif(btrim(r->>'ITMGROUP'), ''),
           private.num(r->>'SALEPRICE'), private.num(r->>'REORDER'),
           private.truthy(r->>'ITMSTOP'),
           -- ACTIVATE missing/blank => active; to be verified against Spark Tech screens.
           (coalesce(btrim(r->>'ACTIVATE'), '') = '' or private.truthy(r->>'ACTIVATE')) and not private.truthy(r->>'ITMSTOP'),
           r->>'ACTIVATE', r->>'ITMSTOP', p_run, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(btrim(r->>'ITMCODE'), '') <> ''
    on conflict (brnid, itmcode) do update set
      name_ar = excluded.name_ar, name_en = excluded.name_en, category = excluded.category,
      subcategory = excluded.subcategory, item_group = excluded.item_group, sale_price = excluded.sale_price,
      reorder_level = excluded.reorder_level, is_stopped = excluded.is_stopped, is_active = excluded.is_active,
      activate_raw = excluded.activate_raw, itmstop_raw = excluded.itmstop_raw,
      last_run_id = excluded.last_run_id, synced_at = excluded.synced_at;
    get diagnostics v_up = row_count;

    delete from public.erp_products t using jsonb_array_elements(p_deletes) d
     where t.brnid = btrim(d->>'BRNID') and t.itmcode = btrim(d->>'ITMCODE');
    get diagnostics v_del = row_count;

  elsif p_table = 'barcodes' then
    -- empty barcodes are skipped (and removed if they used to have a value)
    delete from public.erp_barcodes t using jsonb_array_elements(p_rows) r
     where private.norm_code(r->>'BARCODE') is null
       and t.brnid = btrim(r->>'BRNID') and t.itmcode = btrim(r->>'ITMCODE') and t.unitcode = coalesce(btrim(r->>'UNITCODE'), '');
    select count(*) into v_skipped from jsonb_array_elements(p_rows) r where private.norm_code(r->>'BARCODE') is null;

    insert into public.erp_barcodes as t (brnid, itmcode, unitcode, barcode_raw, barcode_norm, unit_name, unit_factor,
                                          unit_price, last_run_id, synced_at)
    select distinct on (btrim(r->>'BRNID'), btrim(r->>'ITMCODE'), coalesce(btrim(r->>'UNITCODE'), ''))
           btrim(r->>'BRNID'), btrim(r->>'ITMCODE'), coalesce(btrim(r->>'UNITCODE'), ''),
           r->>'BARCODE', private.norm_code(r->>'BARCODE'), nullif(btrim(r->>'UNITNAME'), ''),
           private.num(r->>'UFACT'), private.num(r->>'UNITPRICE'), p_run, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(btrim(r->>'ITMCODE'), '') <> '' and private.norm_code(r->>'BARCODE') is not null
    on conflict (brnid, itmcode, unitcode) do update set
      barcode_raw = excluded.barcode_raw, barcode_norm = excluded.barcode_norm, unit_name = excluded.unit_name,
      unit_factor = excluded.unit_factor, unit_price = excluded.unit_price,
      last_run_id = excluded.last_run_id, synced_at = excluded.synced_at;
    get diagnostics v_up = row_count;

    delete from public.erp_barcodes t using jsonb_array_elements(p_deletes) d
     where t.brnid = btrim(d->>'BRNID') and t.itmcode = btrim(d->>'ITMCODE') and t.unitcode = coalesce(btrim(d->>'UNITCODE'), '');
    get diagnostics v_del = row_count;

  elsif p_table = 'stock' then
    insert into public.erp_stock as t (brnid, itmcode, whsno, batchno, beginqty, purchqty, saleqty, purchrtn, salertn,
                                       inqty, outqty, reserved_qty, last_run_id, synced_at)
    select distinct on (btrim(r->>'BRNID'), btrim(r->>'ITMCODE'), btrim(r->>'WHSNO'), coalesce(btrim(r->>'BATCHNO'), ''))
           btrim(r->>'BRNID'), btrim(r->>'ITMCODE'), btrim(r->>'WHSNO'), coalesce(btrim(r->>'BATCHNO'), ''),
           coalesce(private.num(r->>'BEGINQTY'), 0), coalesce(private.num(r->>'PURCHQTY'), 0),
           coalesce(private.num(r->>'SALEQTY'), 0), coalesce(private.num(r->>'PURCHRTN'), 0),
           coalesce(private.num(r->>'SALERTN'), 0), coalesce(private.num(r->>'INQTY'), 0),
           coalesce(private.num(r->>'OUTQTY'), 0), coalesce(private.num(r->>'RESERVQTY'), 0), p_run, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(btrim(r->>'ITMCODE'), '') <> '' and coalesce(btrim(r->>'WHSNO'), '') <> ''
    on conflict (brnid, itmcode, whsno, batchno) do update set
      beginqty = excluded.beginqty, purchqty = excluded.purchqty, saleqty = excluded.saleqty,
      purchrtn = excluded.purchrtn, salertn = excluded.salertn, inqty = excluded.inqty, outqty = excluded.outqty,
      reserved_qty = excluded.reserved_qty, last_run_id = excluded.last_run_id, synced_at = excluded.synced_at;
    get diagnostics v_up = row_count;

    delete from public.erp_stock t using jsonb_array_elements(p_deletes) d
     where t.brnid = btrim(d->>'BRNID') and t.itmcode = btrim(d->>'ITMCODE')
       and t.whsno = btrim(d->>'WHSNO') and t.batchno = coalesce(btrim(d->>'BATCHNO'), '');
    get diagnostics v_del = row_count;

  elsif p_table = 'warehouses' then
    insert into public.erp_warehouses as t (brnid, whsno, name, last_run_id, synced_at)
    select distinct on (btrim(r->>'BRNID'), btrim(r->>'WHSNO'))
           btrim(r->>'BRNID'), btrim(r->>'WHSNO'), nullif(btrim(r->>'WHSNAME'), ''), p_run, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(btrim(r->>'WHSNO'), '') <> ''
    on conflict (brnid, whsno) do update set name = excluded.name, last_run_id = excluded.last_run_id, synced_at = excluded.synced_at;
    get diagnostics v_up = row_count;

    delete from public.erp_warehouses t using jsonb_array_elements(p_deletes) d
     where t.brnid = btrim(d->>'BRNID') and t.whsno = btrim(d->>'WHSNO');
    get diagnostics v_del = row_count;

  elsif p_table = 'sales_heads' then
    -- bill headers from GLVOUHEAD (sales document types only). VOUDATE is store local time.
    insert into public.erp_sales_heads as t (brnid, gltype, vouno, whsno, voudate, sellerno, userno, posno, shiftno, shiftid,
                                             invqty, invtotal, disctotal, taxtotal, invnetamt, invcostamt, is_active, last_run_id, synced_at)
    select distinct on (btrim(r->>'BRNID'), btrim(r->>'GLTYPE'), btrim(r->>'VOUNO'))
           btrim(r->>'BRNID'), btrim(r->>'GLTYPE'), btrim(r->>'VOUNO'), nullif(btrim(r->>'WHSNO'), ''),
           case when coalesce(r->>'VOUDATE', '') ~ '^\d{4}-\d{2}-\d{2}' then (r->>'VOUDATE')::timestamp at time zone 'Asia/Riyadh' end,
           nullif(btrim(r->>'SELLERNO'), ''), nullif(btrim(r->>'USERNO'), ''), nullif(btrim(r->>'POSNO'), ''),
           nullif(btrim(r->>'SHIFTNO'), ''), nullif(btrim(r->>'SHIFTID'), ''),
           private.num(r->>'INVQTY'), private.num(r->>'INVTOTAL'), private.num(r->>'DISCTOTAL'),
           private.num(r->>'TAXTOTAL'), private.num(r->>'INVNETAMT'), private.num(r->>'INVCOSTAMT'),
           (coalesce(btrim(r->>'ACTIVATE'), '') = '' or private.truthy(r->>'ACTIVATE')), p_run, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(btrim(r->>'VOUNO'), '') <> '' and coalesce(btrim(r->>'GLTYPE'), '') <> ''
    on conflict (brnid, gltype, vouno) do update set
      whsno = excluded.whsno, voudate = excluded.voudate, sellerno = excluded.sellerno, userno = excluded.userno,
      posno = excluded.posno, shiftno = excluded.shiftno, shiftid = excluded.shiftid, invqty = excluded.invqty,
      invtotal = excluded.invtotal, disctotal = excluded.disctotal, taxtotal = excluded.taxtotal,
      invnetamt = excluded.invnetamt, invcostamt = excluded.invcostamt, is_active = excluded.is_active,
      last_run_id = excluded.last_run_id, synced_at = excluded.synced_at;
    get diagnostics v_up = row_count;

    delete from public.erp_sales_heads t using jsonb_array_elements(p_deletes) d
     where t.brnid = btrim(d->>'BRNID') and t.gltype = btrim(d->>'GLTYPE') and t.vouno = btrim(d->>'VOUNO');
    get diagnostics v_del = row_count;

  elsif p_table = 'sales_lines' then
    -- sale lines from ITMSALES; one row per (branch, document type, bill, line serial)
    insert into public.erp_sales_lines as t (brnid, gltype, vouno, invserial, whsno, itmcode, unitcode, ufact, saleqty,
                                             unitprice, discamt, taxamt, itmtotal, totalcost, last_run_id, synced_at)
    select distinct on (btrim(r->>'BRNID'), btrim(r->>'GLTYPE'), btrim(r->>'VOUNO'), btrim(r->>'INVSERIAL'))
           btrim(r->>'BRNID'), btrim(r->>'GLTYPE'), btrim(r->>'VOUNO'), btrim(r->>'INVSERIAL'),
           nullif(btrim(r->>'WHSNO'), ''), btrim(r->>'ITMCODE'), nullif(btrim(r->>'UNITCODE'), ''),
           private.num(r->>'UFACT'), private.num(r->>'SALEQTY'), private.num(r->>'UNITPRICE'),
           private.num(r->>'DISCAMT'), private.num(r->>'TAXAMT'), private.num(r->>'ITMTOTAL'), private.num(r->>'TOTALCOST'), p_run, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(btrim(r->>'VOUNO'), '') <> '' and coalesce(btrim(r->>'INVSERIAL'), '') <> ''
    on conflict (brnid, gltype, vouno, invserial) do update set
      whsno = excluded.whsno, itmcode = excluded.itmcode, unitcode = excluded.unitcode, ufact = excluded.ufact,
      saleqty = excluded.saleqty, unitprice = excluded.unitprice, discamt = excluded.discamt, taxamt = excluded.taxamt,
      itmtotal = excluded.itmtotal, totalcost = excluded.totalcost, last_run_id = excluded.last_run_id, synced_at = excluded.synced_at;
    get diagnostics v_up = row_count;

    delete from public.erp_sales_lines t using jsonb_array_elements(p_deletes) d
     where t.brnid = btrim(d->>'BRNID') and t.gltype = btrim(d->>'GLTYPE') and t.vouno = btrim(d->>'VOUNO')
       and t.invserial = btrim(d->>'INVSERIAL');
    get diagnostics v_del = row_count;

  else
    raise exception 'unknown table %', p_table using errcode = '22023';
  end if;

  update public.sync_runs set
    rows_upserted = jsonb_set(rows_upserted, array[p_table], to_jsonb(coalesce((rows_upserted->>p_table)::int, 0) + v_up)),
    rows_deleted  = jsonb_set(rows_deleted,  array[p_table], to_jsonb(coalesce((rows_deleted->>p_table)::int, 0) + v_del))
  where id = p_run;

  return jsonb_build_object('upserted', v_up, 'deleted', v_del, 'skipped_empty', v_skipped);
end $$;

create or replace function public.sales_bills(
  p_from timestamptz, p_to timestamptz, p_whsno text default null, p_itmcode text default null,
  p_gltype text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with b as (
    -- Spark Tech leaves INVQTY at 0 on POS bills, so pieces are counted from the lines
    -- profit is before tax: (net incl. tax - tax) - cost; null when cost is not synced
    select h.*, coalesce((select sum(l.saleqty) from public.erp_sales_lines l
                           where l.brnid = h.brnid and l.gltype = h.gltype and l.vouno = h.vouno), 0) as line_qty,
           (coalesce(h.invnetamt, 0) - coalesce(h.taxtotal, 0) - h.invcostamt) as profit
    from public.erp_sales_heads h
    where private.is_admin()
      and h.voudate >= p_from and h.voudate < p_to
      and (p_whsno is null or h.whsno = p_whsno)
      and (p_gltype is null or h.gltype = p_gltype)
      and (p_itmcode is null or exists (select 1 from public.erp_sales_lines l
                                         where l.brnid = h.brnid and l.gltype = h.gltype and l.vouno = h.vouno
                                           and upper(l.itmcode) = upper(btrim(p_itmcode))))
  ), page as (
    select * from b order by voudate desc, vouno desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from b),
    'sums', (select jsonb_build_object(
               'sales_net',   coalesce(sum(invnetamt) filter (where is_active and gltype <> '108'), 0),
               'returns_net', coalesce(sum(invnetamt) filter (where is_active and gltype = '108'), 0),
               'sales_bills', count(*) filter (where is_active and gltype <> '108'),
               'return_bills', count(*) filter (where is_active and gltype = '108'),
               'qty', coalesce(sum(line_qty) filter (where is_active and gltype <> '108'), 0),
               'cost', sum(invcostamt) filter (where is_active and gltype <> '108'),
               'profit', sum(case when gltype = '108' then -profit else profit end) filter (where is_active),
               'revenue_ex_tax', sum(case when gltype = '108' then -(coalesce(invnetamt, 0) - coalesce(taxtotal, 0))
                                          else coalesce(invnetamt, 0) - coalesce(taxtotal, 0) end) filter (where is_active)) from b),
    'bills', coalesce((select jsonb_agg(jsonb_build_object(
        'brnid', p.brnid, 'gltype', p.gltype, 'vouno', p.vouno, 'voudate', p.voudate, 'whsno', p.whsno,
        'whs_name', coalesce(wn.name, ew.name), 'posno', p.posno, 'sellerno', p.sellerno, 'userno', p.userno,
        'shiftno', p.shiftno, 'invqty', p.line_qty, 'invtotal', p.invtotal, 'disctotal', p.disctotal,
        'taxtotal', p.taxtotal, 'invnetamt', p.invnetamt, 'cost', p.invcostamt, 'profit', p.profit, 'is_active', p.is_active,
        'lines', coalesce((select jsonb_agg(jsonb_build_object(
                    'invserial', l.invserial, 'itmcode', l.itmcode, 'name_ar', pr.name_ar, 'saleqty', l.saleqty,
                    'unitprice', l.unitprice, 'discamt', l.discamt, 'taxamt', l.taxamt, 'itmtotal', l.itmtotal,
                    'cost', l.totalcost, 'profit', coalesce(l.itmtotal, 0) - coalesce(l.taxamt, 0) - l.totalcost)
                    order by case when l.invserial ~ '^[0-9]+$' then l.invserial::int end, l.invserial)
                  from public.erp_sales_lines l
                  left join public.erp_products pr on pr.brnid = l.brnid and pr.itmcode = l.itmcode
                  where l.brnid = p.brnid and l.gltype = p.gltype and l.vouno = p.vouno), '[]'::jsonb))
        order by p.voudate desc, p.vouno desc)
      from page p
      left join public.warehouse_names wn on wn.brnid = p.brnid and wn.whsno = p.whsno
      left join public.erp_warehouses ew on ew.brnid = p.brnid and ew.whsno = p.whsno), '[]'::jsonb))
$$;
create or replace function public.sales_daily(p_day date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with bounds as (
    select (p_day::timestamp at time zone 'Asia/Riyadh') as t0,
           ((p_day + 1)::timestamp at time zone 'Asia/Riyadh') as t1
  ), h as (
    select h.*, coalesce((select sum(l.saleqty) from public.erp_sales_lines l
                           where l.brnid = h.brnid and l.gltype = h.gltype and l.vouno = h.vouno), 0) as line_qty
    from public.erp_sales_heads h, bounds
    where private.is_admin() and h.whsno is not null and h.voudate >= bounds.t0 and h.voudate < bounds.t1
  ), keys as (
    select distinct brnid, whsno from h
    union
    select brnid, whsno from public.sales_day_reviews where day = p_day and private.is_admin()
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'brnid', k.brnid, 'whsno', k.whsno, 'name', coalesce(wn.name, ew.name),
      'sales_net',    coalesce((select sum(invnetamt) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'), 0),
      'sales_bills',  (select count(*) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'),
      'returns_net',  coalesce((select sum(invnetamt) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype = '108'), 0),
      'return_bills', (select count(*) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype = '108'),
      'qty',          coalesce((select sum(line_qty) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'), 0),
      'cost',         (select sum(invcostamt) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'),
      'profit',       (select sum(case when gltype = '108' then -1 else 1 end * (coalesce(invnetamt, 0) - coalesce(taxtotal, 0) - invcostamt))
                         from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active),
      'revenue_ex_tax', (select sum(case when gltype = '108' then -1 else 1 end * (coalesce(invnetamt, 0) - coalesce(taxtotal, 0)))
                         from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active),
      'discount',     coalesce((select sum(disctotal) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'), 0),
      'cancelled',    (select count(*) from h where h.brnid = k.brnid and h.whsno = k.whsno and not h.is_active),
      'first_at',     (select min(voudate) from h where h.brnid = k.brnid and h.whsno = k.whsno),
      'last_at',      (select max(voudate) from h where h.brnid = k.brnid and h.whsno = k.whsno),
      'review', (select jsonb_build_object('by', coalesce(pr.full_name, pr.email), 'at', r.reviewed_at, 'note', r.note)
                   from public.sales_day_reviews r left join public.profiles pr on pr.id = r.reviewed_by
                  where r.brnid = k.brnid and r.whsno = k.whsno and r.day = p_day))
      order by case when k.whsno ~ '^[0-9]+$' then k.whsno::int end, k.whsno), '[]'::jsonb)
  from keys k
  left join public.warehouse_names wn on wn.brnid = k.brnid and wn.whsno = k.whsno
  left join public.erp_warehouses ew on ew.brnid = k.brnid and ew.whsno = k.whsno
$$;
