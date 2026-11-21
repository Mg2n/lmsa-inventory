"use client";

import { useCallback, useRef, useState } from "react";
import Link from "next/link";
import { RequireStaff } from "@/components/AuthProvider";
import { Scanner } from "@/components/Scanner";
import { QtyStepper } from "@/components/ProductCard";
import { ScanInput, Sheet, Toast, useLocations, useToast } from "@/components/ui";
import { errorText, supabase } from "@/lib/supabase";
import { feedback, fmtQty, normCode } from "@/lib/format";
import type { Location, LookupResult, Product } from "@/lib/types";

type Mode = "remaining" | "count";
interface Entry {
  key: number;
  product: Product;
  qtyHere: number;
}

/**
 * First walk-through of the storage room: scan a shelf label once, then scan
 * items one after another to assign them to that shelf.
 */
export default function SetupPage() {
  return (
    <RequireStaff>
      <SetupScreen />
    </RequireStaff>
  );
}

function SetupScreen() {
  const { locations } = useLocations();
  const toast = useToast();
  const [shelf, setShelf] = useState<Location | null>(null);
  const [mode, setMode] = useState<Mode>("remaining");
  const [entries, setEntries] = useState<Entry[]>([]);
  const [pick, setPick] = useState<Product[] | null>(null);
  const [edit, setEdit] = useState<Entry | null>(null);
  const busy = useRef(false);
  const seq = useRef(0);

  const assign = useCallback(
    async (p: Product, loc: Location) => {
      const here = Number(p.locations.find((l) => l.location_id === loc.id)?.qty ?? 0);
      let res;
      if (mode === "count") {
        res = await supabase.rpc("add_product_location", { p_itmcode: p.itmcode, p_location_id: loc.id, p_delta: 1, p_reason: "setup-count" });
      } else {
        const remaining = Math.max(Number(p.total_qty) - Number(p.located_qty), 0);
        const target = here + (remaining > 0 ? remaining : here > 0 ? 0 : 1);
        res = await supabase.rpc("set_product_location", { p_itmcode: p.itmcode, p_location_id: loc.id, p_qty: target, p_reason: "setup" });
      }
      if (res.error) {
        feedback(false);
        toast.show(errorText(res.error), "error");
        return;
      }
      const np = res.data as Product;
      const qtyHere = Number(np.locations.find((l) => l.location_id === loc.id)?.qty ?? 0);
      feedback(true);
      setEntries((list) => [{ key: ++seq.current, product: np, qtyHere }, ...list.filter((e) => e.product.itmcode !== np.itmcode)].slice(0, 30));
    },
    [mode, toast],
  );

  const onCode = useCallback(
    async (raw: string) => {
      if (busy.current) return;
      busy.current = true;
      try {
        const code = normCode(raw);
        const loc = locations.find((l) => l.code === code);
        if (loc) {
          feedback(true);
          setShelf(loc);
          setEntries([]);
          toast.show(`الرف الحالي: ${loc.code}`);
          return;
        }
        if (!shelf) {
          feedback(false);
          toast.show("امسح ملصق الرف أولاً", "error");
          return;
        }
        const { data, error } = await supabase.rpc("lookup_barcode", { code: raw });
        if (error) return toast.show(errorText(error), "error");
        const r = data as LookupResult;
        if (!r.found) {
          feedback(false);
          toast.show(`غير موجود في سبارك تك: ${raw}`, "error");
        } else if (r.products.length > 1) {
          setPick(r.products);
        } else {
          await assign(r.products[0], shelf);
        }
      } finally {
        busy.current = false;
      }
    },
    [locations, shelf, assign, toast],
  );

  async function saveEdit(e: Entry, qty: number) {
    if (!shelf) return;
    const { data, error } = await supabase.rpc("set_product_location", { p_itmcode: e.product.itmcode, p_location_id: shelf.id, p_qty: qty, p_reason: "setup-fix" });
    if (error) return toast.show(errorText(error), "error");
    const np = data as Product;
    setEntries((list) =>
      qty === 0 ? list.filter((x) => x.key !== e.key) : list.map((x) => (x.key === e.key ? { ...x, product: np, qtyHere: qty } : x)),
    );
    setEdit(null);
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-xl flex-col gap-4 p-4">
      <Toast message={toast.message} tone={toast.tone} />
      <header className="flex items-center justify-between">
        <h1 className="text-xl font-bold">تجهيز الرفوف</h1>
        <Link href="/scan/" className="btn-soft py-2 text-sm">
          رجوع للماسح
        </Link>
      </header>

      <div className={`rounded-3xl p-4 text-center ${shelf ? "bg-olive text-white" : "bg-amber-soft text-amber"}`}>
        {shelf ? (
          <>
            <div className="text-sm opacity-80">الرف الحالي</div>
            <div className="ltr text-4xl font-bold">{shelf.code}</div>
            <div className="text-sm opacity-80">امسح الأصناف واحداً تلو الآخر · امسح ملصق رف آخر للتبديل</div>
          </>
        ) : (
          <div className="text-lg font-semibold">١. امسح ملصق الرف</div>
        )}
      </div>

      <div className="grid grid-cols-2 gap-2 rounded-2xl bg-sand p-1 text-sm">
        <button className={`rounded-xl py-2 font-semibold ${mode === "remaining" ? "bg-card shadow" : "text-muted"}`} onClick={() => setMode("remaining")}>
          كل الكمية غير الموزعة
        </button>
        <button className={`rounded-xl py-2 font-semibold ${mode === "count" ? "bg-card shadow" : "text-muted"}`} onClick={() => setMode("count")}>
          عدّ قطعة بقطعة (+١)
        </button>
      </div>

      <Scanner active={!pick && !edit} onDetected={onCode} className="aspect-[4/3] w-full" />
      <ScanInput onSubmit={onCode} placeholder="أو اكتب رمز الرف / الباركود" />

      {entries.length > 0 && (
        <section className="card space-y-2">
          <h2 className="font-semibold">على هذا الرف ({entries.length})</h2>
          {entries.map((e) => (
            <button key={e.key} onClick={() => setEdit(e)} className="flex w-full items-center justify-between gap-3 rounded-2xl border border-line bg-white px-4 py-3 text-start">
              <span className="min-w-0">
                <span className="block truncate font-semibold">{e.product.name_ar}</span>
                <span className="text-sm text-muted">
                  سبارك تك: <span className="ltr">{fmtQty(e.product.total_qty)}</span>
                  {e.product.mismatch && <span className="text-amber"> · لا يطابق</span>}
                </span>
              </span>
              <span className="ltr text-3xl font-bold text-clay">{fmtQty(e.qtyHere)}</span>
            </button>
          ))}
          <p className="text-center text-xs text-muted">اضغط على صنف لتعديل كميته على هذا الرف</p>
        </section>
      )}

      <Sheet open={!!pick} onClose={() => setPick(null)} title="الباركود مسجّل لأكثر من صنف">
        <div className="space-y-2">
          {pick?.map((p) => (
            <button
              key={p.itmcode}
              className="flex w-full justify-between rounded-2xl border border-line bg-white px-4 py-3"
              onClick={async () => {
                setPick(null);
                if (shelf) await assign(p, shelf);
              }}
            >
              <span>{p.name_ar}</span>
              <span className="ltr text-muted">{p.itmcode}</span>
            </button>
          ))}
        </div>
      </Sheet>

      {edit && <EditSheet entry={edit} onClose={() => setEdit(null)} onSave={(q) => saveEdit(edit, q)} />}
    </main>
  );
}

function EditSheet({ entry, onClose, onSave }: { entry: Entry; onClose: () => void; onSave: (q: number) => void }) {
  const [qty, setQty] = useState(entry.qtyHere);
  return (
    <Sheet open onClose={onClose} title={entry.product.name_ar ?? entry.product.itmcode}>
      <div className="space-y-4">
        <QtyStepper value={qty} onChange={setQty} min={0} />
        <button className="btn-primary w-full" onClick={() => onSave(qty)}>
          حفظ {qty === 0 && "(إزالة من الرف)"}
        </button>
      </div>
    </Sheet>
  );
}
