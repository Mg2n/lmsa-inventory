-- =====================================================================
-- ERP ingest: the only writer of erp_* tables.
-- Called by the erp-ingest Edge Function (service_role) with the agent's
-- shared secret, which is checked here against a SHA-256 hash.
-- Payload rows use the original Spark Tech column names (upper case).
-- =====================================================================

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

  else
    raise exception 'unknown table %', p_table using errcode = '22023';
  end if;

  update public.sync_runs set
    rows_upserted = jsonb_set(rows_upserted, array[p_table], to_jsonb(coalesce((rows_upserted->>p_table)::int, 0) + v_up)),
    rows_deleted  = jsonb_set(rows_deleted,  array[p_table], to_jsonb(coalesce((rows_deleted->>p_table)::int, 0) + v_del))
  where id = p_run;

  return jsonb_build_object('upserted', v_up, 'deleted', v_del, 'skipped_empty', v_skipped);
end $$;

-- After a successful FULL sync, remove rows that no longer exist in Spark Tech.
-- Guarded: a table is only purged when the agent read rows for it and the
-- server received at least that many (or all were legitimately skipped).
create or replace function private.purge_unseen(p_run bigint)
returns jsonb language plpgsql set search_path = ''
as $$
declare
  r record; v_read int; v_seen int; v_total int; n int; v_out jsonb := '{}'::jsonb;
begin
  select * into r from public.sync_runs where id = p_run;
  for v_t in 1..4 loop
    declare tname text := (array['products', 'barcodes', 'stock', 'warehouses'])[v_t];
    begin
      v_read := coalesce((r.rows_read->>tname)::int, 0);
      if v_read = 0 then
        v_out := v_out || jsonb_build_object(tname, 'skipped: nothing read');
        continue;
      end if;
      execute format('select count(*) filter (where last_run_id = $1), count(*) from public.%I', 'erp_' || tname)
        into v_seen, v_total using p_run;
      -- safety: never wipe more than half of a table in one go
      if v_total - v_seen > greatest(v_total / 2, 50) then
        v_out := v_out || jsonb_build_object(tname, format('skipped: would delete %s of %s', v_total - v_seen, v_total));
        continue;
      end if;
      execute format('delete from public.%I where last_run_id is distinct from $1', 'erp_' || tname) using p_run;
      get diagnostics n = row_count;
      v_out := v_out || jsonb_build_object(tname, n);
    end;
  end loop;
  return v_out;
end $$;

-- Single entry point used by the Edge Function.
-- actions: start | batch | finish
create or replace function public.erp_ingest(p_secret text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_action text := p_payload->>'action';
  v_run bigint;
  v_status text;

  v_purge jsonb;
begin
  if p_secret is null or length(p_secret) < 16 or not exists (
       select 1 from private.sync_config
        where secret_hash = encode(extensions.digest(convert_to(p_secret, 'UTF8'), 'sha256'), 'hex')) then
    raise exception 'invalid sync secret' using errcode = '28000';
  end if;

  if v_action = 'start' then
    -- runs that never finished (agent killed, PC off) are marked abandoned
    update public.sync_runs set status = 'abandoned', finished_at = now(), error_message = 'no finish received'
     where status = 'running' and started_at < now() - interval '10 minutes';
    insert into public.sync_runs (full_sync, agent_version, host, rows_read)
    values (coalesce((p_payload->>'full')::boolean, false), left(p_payload->>'agent_version', 40),
            left(p_payload->>'host', 100), coalesce(p_payload->'rows_read', '{}'::jsonb))
    returning id into v_run;
    return jsonb_build_object('run_id', v_run);
  end if;

  v_run := (p_payload->>'run_id')::bigint;
  select status into v_status from public.sync_runs where id = v_run;
  if v_status is null then raise exception 'unknown run %', v_run using errcode = 'P0002'; end if;
  if v_status <> 'running' then raise exception 'run % is %', v_run, v_status using errcode = '22023'; end if;

  if v_action = 'batch' then
    if jsonb_array_length(coalesce(p_payload->'rows', '[]'::jsonb)) > 1000
       or jsonb_array_length(coalesce(p_payload->'deletes', '[]'::jsonb)) > 5000 then
      raise exception 'batch too large' using errcode = '22023';
    end if;
    return private.ingest_batch(v_run, p_payload->>'table', p_payload->'rows', p_payload->'deletes');

  elsif v_action = 'finish' then
    update public.sync_runs set
      rows_read = coalesce(p_payload->'rows_read', rows_read),
      status = case when p_payload->>'status' = 'ok' then 'ok' else 'error' end,
      error_message = left(p_payload->>'error', 2000),
      duration_ms = (p_payload->>'duration_ms')::int,
      finished_at = now()
    where id = v_run;
    if (select full_sync and status = 'ok' from public.sync_runs where id = v_run) then
      v_purge := private.purge_unseen(v_run);
      update public.sync_runs set rows_deleted = rows_deleted || jsonb_build_object('purge', v_purge) where id = v_run;
    end if;
    -- keep the sync_runs table small: 30 days
    delete from public.sync_runs where started_at < now() - interval '30 days';
    return jsonb_build_object('ok', true, 'purge', v_purge);
  end if;

  raise exception 'unknown action %', v_action using errcode = '22023';
end $$;

revoke execute on function public.erp_ingest(text, jsonb) from public, anon, authenticated;
grant execute on function public.erp_ingest(text, jsonb) to service_role;
revoke execute on function private.ingest_batch(bigint, text, jsonb, jsonb), private.purge_unseen(bigint) from public, anon, authenticated;
