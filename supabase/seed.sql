-- Demo storage locations (safe to re-run). Product data comes from the sync
-- (or scripts/test-ingest.mjs with supabase/fixtures/spark_sample.json).
insert into public.locations (code, zone, aisle, shelf, bin, description)
select format('%s-%s-S%s', z, lpad(a::text, 2, '0'), s), z, lpad(a::text, 2, '0'), 'S' || s, null,
       format('المخزن %s - ممر %s - رف %s', z, a, s)
from unnest(array['A', 'B']) z, generate_series(1, 3) a, generate_series(1, 3) s
on conflict (code) do nothing;
