# Clothing store inventory scanner (Spark Tech)

Staff scan a product's barcode with their phone and see how many units Spark Tech says are in stock and **where they are stored**. Spark Tech stays the cash register and the source of truth for products, barcodes and stock. We copy that data **read-only** and add the storage locations Spark Tech doesn't have.

```
Spark Tech ERP (SQL Server "spark", store PC — never written to)
        │ read-only SELECT … WITH (NOLOCK), every 5 minutes, only changed rows
        ▼
Sync agent (PowerShell 5.1 scheduled task, C:\InventorySync)
        │ HTTPS + shared secret
        ▼
Supabase: erp-ingest Edge Function → Postgres (RLS) ◄── Web app (Next.js PWA on Vercel)
                                                          phone Scanner + PC Dashboard
```

| Piece | Where |
|---|---|
| Supabase project | `lmsa-inventory` · ref `gkehjkttaowtjabofpsq` · eu-central-1 · https://supabase.com/dashboard/project/gkehjkttaowtjabofpsq |
| Database (schema, RLS, RPCs, ingest) | `supabase/migrations/*.sql` (already applied) |
| Edge Functions | `supabase/functions/erp-ingest`, `supabase/functions/admin-users` (already deployed) |
| Web app | `web/` (Next.js 15, App Router, TypeScript, Tailwind v4, static export) |
| Sync agent | `agent/InventorySync.ps1`, `agent/install.ps1`, `agent/uninstall.ps1` |
| Sample Spark-shaped data | `supabase/fixtures/spark_sample.json` (`scripts/make-fixture.mjs`) |
| Sync secret (local only, git-ignored) | `secrets/sync_secret.txt` |

---

## 1. Supabase (already done — for reference / a new project)

1. Apply the migrations in `supabase/migrations/` in order (SQL editor or `supabase db push`), then `supabase/seed.sql` for 18 demo shelf locations.
2. Deploy both functions **with JWT verification off** (they authenticate themselves):
   `supabase functions deploy erp-ingest --no-verify-jwt` and `supabase functions deploy admin-users --no-verify-jwt`.
3. Set the agent's shared secret (only its hash is stored):
   ```sql
   insert into private.sync_config (id, secret_hash)
   values (1, encode(extensions.digest('PASTE-SECRET-HERE', 'sha256'), 'hex'))
   on conflict (id) do update set secret_hash = excluded.secret_hash, updated_at = now();
   ```
   To rotate: generate a new secret (`openssl rand -hex 32`), run the SQL above, update `SyncSecret` in `C:\InventorySync\config.json`.
4. **Auth settings (dashboard → Authentication):**
   - Sign In / Providers → Email: turn **off** "Allow new users to sign up" (accounts are created by an admin). Even if left on, new sign-ups get role `pending` and can't see anything.
   - URL Configuration → Site URL: your Vercel URL.
5. **First admin:** Authentication → Users → *Add user* (email + password, "auto confirm"). The **first** user ever created becomes `admin` automatically; everyone after that is `pending` until an admin approves them (or is created from the Users page with a role).

## 2. Web app — run locally

```bash
cd web
cp .env.example .env.local   # URL + publishable key (safe for the browser)
npm install
npm run dev                  # http://localhost:3000
```

Checks: `npx tsc --noEmit`, `npm run lint`, `npm run build` (static site in `web/out`).

## 3. Deploy to Vercel (free tier, HTTPS is required for the camera)

1. Push this folder to a GitHub repository.
2. vercel.com → *Add New… → Project* → import the repo.
3. **Root Directory:** `web` · Framework: Next.js (auto) · Build command/Output: defaults.
4. Environment variables (Production + Preview):
   - `NEXT_PUBLIC_SUPABASE_URL` = `https://gkehjkttaowtjabofpsq.supabase.co`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = `sb_publishable_0LQKqBEnaw9fmLKISQKW-g_-8IlIuBL`
5. Deploy. Every later `git push` redeploys; phones and the PC pick it up automatically (see Auto-update).
6. Put the Vercel URL in Supabase → Authentication → URL Configuration → Site URL.

(CLI alternative: `npm i -g vercel`, then `cd web && vercel --prod`.)

### Add to an iPhone home screen
1. Open the Vercel URL in **Safari** (not Chrome) → log in.
2. Share button → **Add to Home Screen** → Add.
3. Open it from the home-screen icon; allow camera access the first time.
(Android/Chrome: menu → *Install app*.)

### Auto-update (no reinstalling)
- Each build writes `/version.json` with a build id (Vercel git SHA) and bakes the same id into the app.
- The app checks `/version.json` on launch, when it comes back to the foreground and every 30 minutes. If it differs: a small **"إصدار جديد متوفر — اضغط للتحديث"** banner. Tapping it clears the service-worker caches and reloads.
- The service worker (`web/public/sw.js`) is network-first for pages and cache-first for hashed `/_next/static` files, so a new deploy is never hidden behind an old cache. Supabase calls are never cached.

## 4. Install the sync agent on the store PC

Requirements: Windows 10 (built-in PowerShell 5.1). **Nothing is installed**; no Node/Python.

The store's SQL Server uses **Windows Authentication mode** only, so the agent signs in with a
dedicated **local Windows account `inventory_sync`** (a normal user, not an administrator) instead of
a SQL login. SQL Server's settings are not changed and nothing is restarted.

**What you need:** the `agent` folder (or `InventorySync-agent.zip`), the **sync secret**
(`secrets/sync_secret.txt` on the project owner's Mac), and someone who can sign in to SSMS on the
store PC with admin rights (Windows Authentication, as Spark Tech's admin normally does).

1. Copy the `agent` folder to the store PC's Desktop (zip from Drive/GitHub: right-click → Properties → **Unblock** → OK, then Extract All).
2. Start → type *PowerShell* → right-click → **Run as administrator**.
3. Run (change `-SqlServer` if SSMS's connect window shows something other than `.` / `(local)`, e.g. `".\SQLEXPRESS"`):
   ```powershell
   cd $HOME\Desktop\agent
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -IngestUrl https://gkehjkttaowtjabofpsq.supabase.co/functions/v1/erp-ingest -SqlServer "." -SqlDatabase "Spark"
   ```
4. The installer:
   1. creates the Windows account `inventory_sync` (random password nobody needs, hidden from the sign-in screen, not an administrator) and gives that account only the **"Log on as a batch job"** right, which Windows requires to run a scheduled task as it (the store PC grants it only to Administrators by default; `uninstall.ps1` removes it);
   2. asks for the **sync secret** (or reads it from a text file with `-SecretFile C:\path\secret.txt`, then deletes that file) (paste, Enter — nothing shows while typing) and writes `C:\InventorySync\config.json`; locks the folder so only Administrators/SYSTEM can change it and `inventory_sync` can only read it (and write logs/state/out);
   3. writes **`create-login.sql` to the Desktop** and pauses. In SSMS: **File → Open → File… → Desktop\create-login.sql → F5** → "Commands completed successfully." Then press Enter in PowerShell. The script only creates a Windows login for `PCNAME\inventory_sync` and grants **SELECT on ITEMES, ITMUNIT, ITEMSMASTER, WAREHOUSES** — no other permissions, nothing written to Spark Tech data;
   4. runs a **dry run as `inventory_sync`** (reads Spark Tech, writes `C:\InventorySync\out\dryrun-*.json`, sends nothing) and shows the log;
   5. only if that succeeds, registers the task `InventorySync` (every 5 minutes, as `inventory_sync`).
5. Within ~5 minutes the app's *Sync* page shows the first full run.

Running the installer again is safe (it renews the account's password and the task). Use `-Force` to re-enter the sync secret.

**Useful commands (PowerShell):**
```powershell
Start-ScheduledTask -TaskName InventorySync               # run now
Get-ScheduledTaskInfo -TaskName InventorySync             # last result (0 = OK, 2 = skipped, already running)
Get-Content C:\InventorySync\logs\sync-$(Get-Date -Format yyyyMMdd).log -Tail 30
Remove-Item C:\InventorySync\state\meta.txt; Start-ScheduledTask -TaskName InventorySync   # force a full snapshot on the next run
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1  # remove task, folder and the inventory_sync account (-KeepLogs to keep logs)
```

**What a run does:** below-normal priority · single instance (lock file + task setting) · TLS 1.2 · 4 SELECTs (`ITEMSMASTER` is summed per item+warehouse in SQL) · 90 s SQL timeout · compares with the last successful run and sends **only changed rows and deletions** in batches of 500 · full snapshot once every 24 h (lets the server drop rows deleted in Spark Tech) · 4-minute hard limit (the very first full run on the store PC reads ~13,600 rows) · retries network/5xx errors (2 s, 5 s, 10 s) · reports every run to `sync_runs` · log files kept 7 days. In a typical 5-minute window almost nothing changes, so a run is a few seconds of SQL reads and one or two small HTTPS calls.

## 5. Using it

**Phone — Scanner (`/scan`)**: point the camera at the label (vibration on Android + a short beep on every phone). The card shows the Arabic name, price, the **big Spark Tech quantity**, reserved quantity, and each storage location with its quantity. Quick actions: *add to location*, *move* (part or all), *edit quantity* (0 removes). Not found → "غير موجود في سبارك تك" + last sync time. Typing text searches by name (Arabic spelling-tolerant: ة/ه, أ/ا, ى/ي), item code or barcode. Scanning a **shelf label** shows what's on that shelf.

**Phone — Shelf setup (`/scan/setup`)**: scan a shelf label once, then scan items one after another. Two modes: *all unlocated quantity* (puts the item's remaining Spark Tech quantity on this shelf) or *count piece by piece* (+1 per scan). Tap a line to correct it. Scan another shelf label to switch.

**PC — Dashboard (`/dashboard`)**: products with stock and locations; filters *no location*, *negative stock*, *below reorder level*, *mismatch* (location total ≠ Spark Tech total); every search box accepts a USB barcode scanner (it types + Enter). *Locations & labels*: create a whole grid (e.g. zone A × 3 aisles × 4 shelves → `A-01-S1` …), single locations, activate/deactivate, print Code 128 shelf labels (A4, 3 per row). *Sync*: last successful sync, rows, errors, a red warning after 15 minutes without a sync, and barcode data-quality notes. *Quantity check*: the stock formula next to the raw columns to compare with Spark Tech. *Users* (admin): create accounts, change roles, reset passwords.

## 6. Test checklist

Backend (already run during the build — re-run after changes):
- [x] `node scripts/test-ingest.mjs` with `INGEST_URL` and `SYNC_SECRET`: start → batches → finish OK; wrong secret → 401; GET → 405.
- [x] `lookup_barcode('  010014tr ')` → 2 products (duplicate barcode), `0900044LA` → by barcode, `90003` → by item code, unknown → `found:false` + last sync, `999` → negative stock flagged.
- [x] set/add/move RPCs: quantities, mismatch flag and `location_movements` rows correct.
- [x] Arabic search `منوعة` finds `ملابس منوعه`.
- [x] Security: anon can't read or call anything; `pending` user sees 0 products and can't write or self-promote; staff can't create locations, can't write `erp_*`, can't call `erp_ingest`.
- [x] Agent (fixture mode, real Edge Function): first run FULL, second run sends nothing, changed qty + deleted item → +1/−1 only, `-DryRun` writes JSON and sends nothing, bad secret → exit 1 with logged 401, SQL guard refuses 10 kinds of non-SELECT/unsafe SQL.
- [x] Web: `tsc`, `eslint`, `next build` clean; login page renders RTL on a phone viewport.

To do on site (needs the real devices / data):
- [ ] Create the first admin (section 1.5), log in on the PC and on an iPhone.
- [ ] Scan 5 different real labels (Code 128 with suffixes like `010014Tr`, one EAN-13): each opens the right item.
- [ ] Turn the phone camera permission off → manual entry still works.
- [ ] On the store PC: run `install.ps1`, run `create-login.sql` in SSMS when it pauses, confirm the dry run succeeds, then the first sync appears on the *Sync* page.
- [ ] **Verify the stock formula** on the *Quantity check* page for ~5 items (include one generic "ملابس منوعه" and one recently sold) against what Spark Tech shows. Adjust `qty_computed` in `erp_stock` if it differs.
- [ ] Verify `ACTIVATE`/`ITMSTOP` meaning on one stopped item (see Decisions).
- [ ] Ring up a sale in Spark Tech → within 5 minutes the scanned quantity drops by one.
- [ ] Watch the checkout PC during a sync (Task Manager): no noticeable slowdown.
- [ ] Shelf setup: create zone A, print labels, label 2 shelves, scan 10 items in.
- [ ] Deploy a trivial change → the "new version" banner appears on the phone.
- [ ] Unplug the store PC's network for 20 minutes → red "no sync" warning on the dashboard.

## Decisions

- **New Supabase project** `lmsa-inventory` (eu-central-1, $0/month) so the store's data is separate from other apps.
- **Static Next.js export** (no server code): fast, cacheable, light on the old PC, trivially hosted on Vercel; auth runs in the browser with Supabase and is enforced by RLS. A native wrapper (Capacitor) can load the same build later.
- **Arabic only, RTL**, font IBM Plex Sans Arabic. Strings are inline Arabic for now (English toggle = TODO).
- **Roles:** `admin`, `staff`, plus `pending` for unapproved accounts. The first account becomes admin. User creation runs in the `admin-users` Edge Function so the service-role key never reaches the browser.
- **All location writes go through RPCs** (`set_/add_/move_product_location`) that check the role and always write `location_movements`. Staff can't edit `product_locations` directly.
- **Barcodes:** normalised by removing all whitespace/control characters and upper-casing (same rule in SQL and the app). `barcode_norm` is **indexed, not unique**, because the real data has duplicates; a scan that matches several items shows a picker, and duplicates / odd values are listed on the *Sync* page (`v_barcode_issues`). Empty barcodes are skipped. If nothing matches, the scan falls back to an exact item code.
- **Single branch assumed:** our tables (`product_locations`) key on `itmcode`; the `erp_*` tables keep `brnid`.
- **Stock:** `qty_computed` is a generated column with the formula from the spec, summed per item; `RESERVQTY` is shown separately. Because ITEMSMASTER has ~6 rows per item, the agent sums them per item + warehouse inside SQL Server (`GROUP BY`) — 6× less work for the old PC. The check page therefore shows warehouse totals.
- **"Mismatch"** = the item has at least one location and the location total ≠ Spark Tech total. Items with no location are their own filter ("no location", only items with stock > 0).
- **ACTIVATE / ITMSTOP:** `is_active = (ACTIVATE empty or truthy) and not ITMSTOP`. Raw values are kept in `activate_raw`/`itmstop_raw` until verified on site.
- **Sync = change detection, not full reloads:** the agent keeps the last snapshot in `C:\InventorySync\state` and sends only changes + deletions; a full snapshot every 24 h lets the server purge rows that disappeared. Safety: the purge never removes more than half a table at once, and the agent refuses to sync if ITEMES returns 0 rows.
- **Shared secret stored as a SHA-256 hash in the database** (`private.sync_config`) so it can be rotated with one SQL statement; the Edge Function calls `erp_ingest()` with the service role, and that function is not executable by browsers.
- **Agent signs in as a local Windows account `inventory_sync`, not a SQL login** (decided 2026-11-22): the store's SQL Server is in Windows Authentication mode only, and switching it to mixed mode would need a SQL Server restart. The account is a normal user (the agent refuses to run as anyone else or as an administrator), has SELECT on 4 tables only, its random password is known to nobody (only Task Scheduler stores it), and it is hidden from the sign-in screen. The task runs as that account even when nobody is logged in. `C:\InventorySync` is locked to Administrators/SYSTEM (+ read for the account), which also stops other users editing the script. A config with `"SqlAuth": "Sql"` (SQL login + password) is still supported if mixed mode is ever enabled.
- **Dates in agent logs** use the invariant (Gregorian) calendar even on an Arabic/Hijri Windows locale.
- `sync_runs` older than 30 days are deleted automatically.
- Supabase security advisor shows "signed-in users can execute SECURITY DEFINER functions" for the location/role RPCs — intentional: each one checks the caller's role first. `private.sync_config` has RLS with no policies on purpose (no API access at all).

- **Quantities count only the store's warehouse** (decided 2026-11-24): Spark Tech's `ITEMSMASTER` holds every item in 6 warehouses (WHSNO 1–6); the store is warehouse **3 "فرع عريجا"** — confirmed by the owner (item 001 = 16 in Spark Tech, not 48 for all six). All warehouses are still synced; `public.stock_warehouses` lists which ones count (empty = all), and `v_store_stock` feeds the totals. To change it: `insert into public.stock_warehouses (brnid, whsno, note) values ('1','4','…');` (admin).

- **Sales log + daily review** (decided 2026-11-24): agent 1.3 reads bill headers from `GLVOUHEAD` (only the sales document types found in `ITMSALES`: 104 sales, 108 returns, 71) and lines from `ITMSALES`. SQL Server grants the agent **only the listed columns** of those two tables — no customer (BENEF*), cost or ZATCA columns. Pages *سجل المبيعات* and *المراجعة اليومية* are admin-only; bills marked inactive (ACTIVATE = 0, assumed cancelled) are listed but left out of totals. Purchases/transfers: the store's Spark Tech has none (ITMPURCHASE / ITMSTKDET / ITMSTKHEAD are empty), so there is nothing to copy.
- **Signed self-update** (decided 2026-11-24): `scripts/publish-agent.py` signs `agent/InventorySync.ps1` with `secrets/agent_signing_key.pem` (RSA-3072, git-ignored, never leaves the owner's Mac) and writes `web/public/agent/manifest.json` + the script; a push deploys it. On the store PC the SYSTEM task `InventorySync-Update` (every 6 h) runs `Update-Agent.ps1`, which installs a newer agent only if the SHA-256 and signature check out against `update-public-key.xml`, keeps the previous one as `InventorySync.prev.ps1`, and never touches SQL Server, Spark Tech or config. New SQL permissions still need SSMS.

**Releasing an agent update:** bump `$AgentVersion` in `agent/InventorySync.ps1` → `source ~/venv/bin/activate && python scripts/publish-agent.py` → commit + push. Store PCs update within 6 hours (log: `C:\InventorySync\logs\update-*.log`; the Sync page shows the new version).

## TODO (skipped in v1)

- [ ] CSV export of products / movements.
- [ ] Realtime updates on the dashboard when a phone changes a location (Supabase Realtime on `product_locations`).
- [ ] English toggle (move inline strings to a dictionary).
- [ ] Movement history page (data is already logged in `location_movements`).
- [ ] Sync-agent self-update (version file in Supabase Storage, SHA-256 check, swap + rollback). The script already has `$AgentVersion` and reports it on every run.
