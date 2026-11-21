// erp-ingest — receives read-only snapshots from the store-PC sync agent and
// upserts them into the erp_* tables via public.erp_ingest().
//
// Auth: header `x-sync-secret` (shared secret; only its SHA-256 hash lives in
// the database). The service-role key never leaves Supabase.
//
// Body (JSON):
//   { action: "start",  agent_version, host, full, rows_read }        -> { run_id }
//   { action: "batch",  run_id, table, rows: [...], deletes: [...] }  -> { upserted, deleted, skipped_empty }
//   { action: "finish", run_id, status: "ok"|"error", error, rows_read, duration_ms }
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MAX_BODY_BYTES = 4 * 1024 * 1024;
const MAX_ROWS = 1000;
const TABLES = new Set(["products", "barcodes", "stock", "warehouses"]);
const ACTIONS = new Set(["start", "batch", "finish"]);

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  // newer projects expose secret keys as a JSON map
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keys) {
    try {
      const parsed = JSON.parse(keys) as Record<string, string>;
      const first = parsed.default ?? Object.values(parsed)[0];
      if (first) return first;
    } catch { /* ignore */ }
  }
  throw new Error("service key not configured");
}

const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), {
  auth: { persistSession: false, autoRefreshToken: false },
});

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const secret = req.headers.get("x-sync-secret") ?? "";
  if (secret.length < 16) return json(401, { error: "missing secret" });

  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > MAX_BODY_BYTES) return json(413, { error: "body too large" });

  let payload: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });
    payload = JSON.parse(text);
  } catch {
    return json(400, { error: "invalid JSON" });
  }

  const action = String(payload?.action ?? "");
  if (!ACTIONS.has(action)) return json(400, { error: "unknown action" });
  if (action !== "start" && !Number.isInteger(Number(payload.run_id))) {
    return json(400, { error: "run_id required" });
  }
  if (action === "batch") {
    if (!TABLES.has(String(payload.table))) return json(400, { error: "unknown table" });
    const rows = payload.rows ?? [];
    const deletes = payload.deletes ?? [];
    if (!Array.isArray(rows) || !Array.isArray(deletes)) return json(400, { error: "rows/deletes must be arrays" });
    if (rows.length > MAX_ROWS) return json(400, { error: `max ${MAX_ROWS} rows per batch` });
  }

  const { data, error } = await db.rpc("erp_ingest", { p_secret: secret, p_payload: payload });
  if (error) {
    const unauthorized = error.code === "28000" || /invalid sync secret/.test(error.message);
    console.error("erp_ingest failed", action, error.code, error.message);
    return json(unauthorized ? 401 : 400, { error: unauthorized ? "unauthorized" : error.message });
  }
  return json(200, data);
});
