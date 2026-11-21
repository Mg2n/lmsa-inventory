"use client";

import { useCallback, useState } from "react";
import Link from "next/link";
import { RequireStaff, useAuth } from "@/components/AuthProvider";
import { Scanner } from "@/components/Scanner";
import { ProductCard } from "@/components/ProductCard";
import { ScanInput, SyncBadge, Toast, useLastSync, useLocations, useToast } from "@/components/ui";
import { errorText, supabase } from "@/lib/supabase";
import { feedback, fmtQty, normCode, timeAgo } from "@/lib/format";
import type { Location, LookupResult, Product, ProductRow } from "@/lib/types";

type View =
  | { kind: "idle" }
  | { kind: "loading"; code: string }
  | { kind: "product"; product: Product }
  | { kind: "pick"; products: Product[] }
  | { kind: "search"; q: string; rows: ProductRow[] }
  | { kind: "location"; location: Location; items: { itmcode: string; name_ar: string | null; qty: number }[] }
  | { kind: "notfound"; code: string; lastOk: string | null };

export default function ScanPage() {
  return (
    <RequireStaff>
      <ScanScreen />
    </RequireStaff>
  );
}

function ScanScreen() {
  const { signOut } = useAuth();
  const sync = useLastSync();
  const { locations } = useLocations();
  const toast = useToast();
  const [view, setView] = useState<View>({ kind: "idle" });
  const cameraOn = view.kind === "idle";

  const lookup = useCallback(
    async (raw: string, fromCamera: boolean) => {
      const code = normCode(raw);
      // a shelf label?
      const loc = locations.find((l) => l.code === code);
      if (loc) {
        if (fromCamera) feedback(true);
        const { data } = await supabase.rpc("location_contents", { p_location_id: loc.id });
        setView({ kind: "location", location: loc, items: (data as never[]) ?? [] });
        return;
      }
      setView({ kind: "loading", code: raw });
      const { data, error } = await supabase.rpc("lookup_barcode", { code: raw });
      if (error) {
        toast.show(errorText(error), "error");
        setView({ kind: "idle" });
        return;
      }
      const r = data as LookupResult;
      if (r.found && r.products.length === 1) {
        if (fromCamera) feedback(true);
        setView({ kind: "product", product: r.products[0] });
      } else if (r.found) {
        if (fromCamera) feedback(true);
        setView({ kind: "pick", products: r.products });
      } else if (!fromCamera && raw.trim().length >= 2) {
        // typed text: fall back to name / code search
        const s = await supabase.rpc("search_products", { p_q: raw, p_filter: null }).range(0, 29);
        const rows = (s.data as ProductRow[]) ?? [];
        if (rows.length) setView({ kind: "search", q: raw, rows });
        else setView({ kind: "notfound", code: raw, lastOk: r.last_sync?.last_ok_at ?? null });
      } else {
        feedback(false);
        setView({ kind: "notfound", code: raw, lastOk: r.last_sync?.last_ok_at ?? null });
      }
    },
    [locations, toast],
  );

  const onDetected = useCallback((code: string) => lookup(code, true), [lookup]);

  async function openItem(itmcode: string) {
    const { data } = await supabase.rpc("get_product", { p_itmcode: itmcode });
    if (data) setView({ kind: "product", product: data as Product });
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-xl flex-col gap-4 p-4 pb-[calc(1rem+env(safe-area-inset-bottom))]">
      <Toast message={toast.message} tone={toast.tone} />
      <header className="flex items-center justify-between gap-2">
        <h1 className="text-xl font-bold">ماسح المخزون</h1>
        <SyncBadge sync={sync} />
      </header>

      <nav className="grid grid-cols-3 gap-2 text-sm">
        <Link href="/scan/setup/" className="btn-soft py-2">
          تجهيز الرفوف
        </Link>
        <Link href="/dashboard/" className="btn-soft py-2">
          لوحة التحكم
        </Link>
        <button onClick={signOut} className="btn-soft py-2">
          خروج
        </button>
      </nav>

      {cameraOn ? (
        <Scanner active={cameraOn} onDetected={onDetected} className="aspect-[4/5] max-h-[55dvh] w-full" />
      ) : (
        <button className="btn-olive w-full py-4 text-lg" onClick={() => setView({ kind: "idle" })}>
          📷 مسح التالي
        </button>
      )}

      <ScanInput onSubmit={(v) => lookup(v, false)} />

      {view.kind === "loading" && <div className="card text-center text-muted">جارٍ البحث عن <span className="ltr">{view.code}</span>…</div>}

      {view.kind === "product" && (
        <ProductCard
          product={view.product}
          onChange={(p) => setView({ kind: "product", product: p })}
          onToast={toast.show}
        />
      )}

      {view.kind === "pick" && (
        <div className="card space-y-2">
          <p className="font-semibold">هذا الباركود مسجّل لأكثر من صنف — اختر الصنف:</p>
          {view.products.map((p) => (
            <button key={p.itmcode} className="flex w-full items-center justify-between rounded-2xl border border-line bg-white px-4 py-3 text-start" onClick={() => setView({ kind: "product", product: p })}>
              <span>
                <b>{p.name_ar}</b> <span className="ltr text-sm text-muted">{p.itmcode}</span>
              </span>
              <span className="ltr text-2xl font-bold text-olive">{fmtQty(p.total_qty)}</span>
            </button>
          ))}
        </div>
      )}

      {view.kind === "search" && (
        <div className="card space-y-2">
          <p className="text-muted">نتائج البحث عن «{view.q}»</p>
          {view.rows.map((r) => (
            <button key={r.itmcode} className="flex w-full items-center justify-between gap-3 rounded-2xl border border-line bg-white px-4 py-3 text-start" onClick={() => openItem(r.itmcode)}>
              <span className="min-w-0">
                <span className="block truncate font-semibold">{r.name_ar}</span>
                <span className="ltr block text-start text-sm text-muted">
                  {r.itmcode} {r.location_codes ? `· ${r.location_codes}` : ""}
                </span>
              </span>
              <span className={`ltr text-2xl font-bold ${r.negative_stock ? "text-danger" : "text-olive"}`}>{fmtQty(r.total_qty)}</span>
            </button>
          ))}
        </div>
      )}

      {view.kind === "location" && (
        <div className="card space-y-3">
          <div className="flex items-baseline justify-between">
            <h2 className="ltr text-2xl font-bold">{view.location.code}</h2>
            <span className="text-muted">{view.location.description}</span>
          </div>
          {view.items.length === 0 ? (
            <p className="text-muted">هذا الرف فارغ.</p>
          ) : (
            view.items.map((i) => (
              <button key={i.itmcode} onClick={() => openItem(i.itmcode)} className="flex w-full items-center justify-between rounded-2xl border border-line bg-white px-4 py-3 text-start">
                <span>
                  {i.name_ar} <span className="ltr text-sm text-muted">{i.itmcode}</span>
                </span>
                <span className="ltr text-2xl font-bold text-clay">{fmtQty(i.qty)}</span>
              </button>
            ))
          )}
        </div>
      )}

      {view.kind === "notfound" && (
        <div className="card text-center">
          <p className="text-2xl font-bold text-danger">غير موجود في سبارك تك</p>
          <p className="ltr mt-2 text-lg">{view.code}</p>
          <p className="mt-3 text-sm text-muted">
            آخر مزامنة: {timeAgo(view.lastOk)} — إذا أُضيف الصنف حديثاً انتظر المزامنة التالية (كل ٥ دقائق).
          </p>
        </div>
      )}
    </main>
  );
}
