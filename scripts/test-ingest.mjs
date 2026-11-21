// Pushes a Spark-shaped fixture through the erp-ingest Edge Function the same
// way the sync agent does (start -> batches of 500 -> finish).
// Usage:
//   INGEST_URL=https://<ref>.supabase.co/functions/v1/erp-ingest \
//   SYNC_SECRET=$(cat secrets/sync_secret.txt) \
//   node scripts/test-ingest.mjs [fixture.json] [--full]
import { readFileSync } from "node:fs";

const url = process.env.INGEST_URL;
const secret = process.env.SYNC_SECRET;
if (!url || !secret) throw new Error("INGEST_URL and SYNC_SECRET are required");
const file = process.argv.find((a) => a.endsWith(".json")) ?? "supabase/fixtures/spark_sample.json";
const full = process.argv.includes("--full");
const data = JSON.parse(readFileSync(file, "utf8"));

const map = { products: data.ITEMES, barcodes: data.ITMUNIT, stock: data.ITEMSMASTER, warehouses: data.WAREHOUSES };
const rowsRead = Object.fromEntries(Object.entries(map).map(([k, v]) => [k, v.length]));

async function call(body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json; charset=utf-8", "x-sync-secret": secret },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${res.status} ${JSON.stringify(json)}`);
  return json;
}

const t0 = Date.now();
const { run_id } = await call({ action: "start", agent_version: "test-ingest", host: "dev-mac", full, rows_read: rowsRead });
console.log("run", run_id);
for (const [table, rows] of Object.entries(map)) {
  for (let i = 0; i < rows.length; i += 500) {
    const r = await call({ action: "batch", run_id, table, rows: rows.slice(i, i + 500), deletes: [] });
    console.log(table, i, r);
  }
}
const fin = await call({ action: "finish", run_id, status: "ok", rows_read: rowsRead, duration_ms: Date.now() - t0 });
console.log("finish", JSON.stringify(fin));
