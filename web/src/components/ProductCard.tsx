"use client";

import { useMemo, useState } from "react";
import { errorText, supabase } from "@/lib/supabase";
import { fmtPrice, fmtQty, normCode } from "@/lib/format";
import type { Location, Product, ProductLocation } from "@/lib/types";
import { Sheet, useLocations } from "./ui";

type Action =
  | { kind: "assign" }
  | { kind: "move"; from: ProductLocation }
  | { kind: "set"; at: ProductLocation }
  | null;

/** Result card: name, price, big Spark Tech quantity, storage locations + quick actions. */
export function ProductCard({
  product,
  onChange,
  onToast,
}: {
  product: Product;
  onChange: (p: Product) => void;
  onToast?: (msg: string, tone?: "ok" | "error") => void;
}) {
  const [action, setAction] = useState<Action>(null);
  const p = product;
  const unlocated = Math.max(Number(p.total_qty) - Number(p.located_qty), 0);

  return (
    <div className="card space-y-4">
      <div>
        <div className="flex flex-wrap items-start justify-between gap-2">
          <h2 className="text-2xl font-bold leading-snug">{p.name_ar ?? p.name_en ?? p.itmcode}</h2>
          <span className="text-xl font-semibold text-clay">{fmtPrice(p.sale_price)}</span>
        </div>
        {p.name_en && <p className="ltr text-start text-sm text-muted">{p.name_en}</p>}
        <div className="mt-2 flex flex-wrap gap-2 text-sm">
          <span className="chip bg-sand text-muted">
            صنف <b className="ltr text-ink">{p.itmcode}</b>
          </span>
          {p.barcodes.slice(0, 3).map((b) => (
            <span key={b.barcode} className="chip bg-sand text-muted">
              <span className="ltr">{b.barcode}</span>
            </span>
          ))}
          {p.category && <span className="chip bg-sand text-muted">{p.category}</span>}
          {!p.is_active && <span className="chip bg-amber-soft text-amber">موقوف</span>}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className={`rounded-3xl p-4 text-center ${p.negative_stock ? "bg-danger-soft" : "bg-olive-soft"}`}>
          <div className="text-sm text-muted">الكمية في سبارك تك</div>
          <div className={`ltr text-6xl font-bold leading-tight ${p.negative_stock ? "text-danger" : "text-olive"}`}>
            {fmtQty(p.total_qty)}
          </div>
          {Number(p.reserved_qty) > 0 && <div className="text-sm text-muted">محجوز: {fmtQty(p.reserved_qty)}</div>}
        </div>
        <div className={`rounded-3xl p-4 text-center ${p.mismatch ? "bg-amber-soft" : "bg-sand"}`}>
          <div className="text-sm text-muted">في المواقع</div>
          <div className={`ltr text-6xl font-bold leading-tight ${p.mismatch ? "text-amber" : "text-ink"}`}>
            {fmtQty(p.located_qty)}
          </div>
          {p.mismatch && <div className="text-sm font-semibold text-amber">لا يطابق سبارك تك</div>}
        </div>
      </div>
      {p.negative_stock && (
        <p className="rounded-2xl bg-danger-soft px-4 py-2 text-sm text-danger">الكمية سالبة في سبارك تك — تحتاج مراجعة.</p>
      )}

      <div>
        <h3 className="mb-2 font-semibold">أماكن التخزين</h3>
        {p.locations.length === 0 ? (
          <p className="rounded-2xl bg-sand px-4 py-3 text-muted">لا يوجد موقع مسجّل لهذا الصنف بعد.</p>
        ) : (
          <ul className="space-y-2">
            {p.locations.map((l) => (
              <li key={l.location_id} className="flex items-center gap-3 rounded-2xl border border-line bg-white px-4 py-3">
                <div className="min-w-0 flex-1">
                  <div className="ltr text-start text-lg font-bold">{l.code}</div>
                  {l.description && <div className="truncate text-sm text-muted">{l.description}</div>}
                </div>
                <div className="ltr text-3xl font-bold text-clay">{fmtQty(l.qty)}</div>
                <div className="flex flex-col gap-1">
                  <button className="rounded-xl bg-sand px-3 py-1 text-sm" onClick={() => setAction({ kind: "move", from: l })}>
                    نقل
                  </button>
                  <button className="rounded-xl bg-sand px-3 py-1 text-sm" onClick={() => setAction({ kind: "set", at: l })}>
                    تعديل
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
        <button className="btn-primary mt-3 w-full" onClick={() => setAction({ kind: "assign" })}>
          ＋ إضافة إلى موقع
        </button>
      </div>

      {action && (
        <ActionSheet
          product={p}
          action={action}
          defaultQty={action.kind === "assign" ? unlocated || 1 : undefined}
          onClose={() => setAction(null)}
          onDone={(np, msg) => {
            onChange(np);
            onToast?.(msg);
            setAction(null);
          }}
          onError={(m) => onToast?.(m, "error")}
        />
      )}
    </div>
  );
}

function ActionSheet({
  product,
  action,
  defaultQty,
  onClose,
  onDone,
  onError,
}: {
  product: Product;
  action: NonNullable<Action>;
  defaultQty?: number;
  onClose: () => void;
  onDone: (p: Product, msg: string) => void;
  onError: (msg: string) => void;
}) {
  const { locations } = useLocations();
  const [target, setTarget] = useState<Location | null>(null);
  const initial =
    action.kind === "move" ? Number(action.from.qty) : action.kind === "set" ? Number(action.at.qty) : defaultQty ?? 1;
  const [qty, setQty] = useState<number>(initial);
  const [busy, setBusy] = useState(false);

  const title =
    action.kind === "assign" ? "إضافة إلى موقع" : action.kind === "move" ? `نقل من ${action.from.code}` : `تعديل الكمية في ${action.at.code}`;
  const needsTarget = action.kind !== "set";
  const maxQty = action.kind === "move" ? Number(action.from.qty) : undefined;

  async function save() {
    setBusy(true);
    let res;
    if (action.kind === "assign") {
      res = await supabase.rpc("add_product_location", {
        p_itmcode: product.itmcode, p_location_id: target!.id, p_delta: qty, p_reason: "assign",
      });
    } else if (action.kind === "move") {
      res = await supabase.rpc("move_product_location", {
        p_itmcode: product.itmcode, p_from: action.from.location_id, p_to: target!.id, p_qty: qty, p_reason: "move",
      });
    } else {
      res = await supabase.rpc("set_product_location", {
        p_itmcode: product.itmcode, p_location_id: action.at.location_id, p_qty: qty, p_reason: "adjust",
      });
    }
    setBusy(false);
    if (res.error) return onError(errorText(res.error));
    const msg = action.kind === "assign" ? `أُضيف إلى ${target!.code}` : action.kind === "move" ? `نُقل إلى ${target!.code}` : qty === 0 ? "أُزيل من الموقع" : "تم تحديث الكمية";
    onDone(res.data as Product, msg);
  }

  return (
    <Sheet open onClose={onClose} title={title}>
      <div className="space-y-4">
        {needsTarget && (
          <LocationPicker
            locations={locations.filter((l) => l.is_active && (action.kind !== "move" || l.id !== action.from.location_id))}
            value={target}
            onChange={setTarget}
          />
        )}
        <QtyStepper value={qty} onChange={setQty} max={maxQty} min={action.kind === "set" ? 0 : 1} />
        <button className="btn-primary w-full text-lg" disabled={busy || (needsTarget && !target)} onClick={save}>
          {busy ? "جارٍ الحفظ…" : "حفظ"}
        </button>
      </div>
    </Sheet>
  );
}

export function QtyStepper({ value, onChange, min = 0, max }: { value: number; onChange: (n: number) => void; min?: number; max?: number }) {
  const clamp = (n: number) => Math.max(min, max != null ? Math.min(max, n) : n);
  return (
    <div>
      <label className="mb-1 block text-sm text-muted">الكمية{max != null && ` (حتى ${fmtQty(max)})`}</label>
      <div className="flex items-center gap-3">
        <button type="button" className="btn-soft h-14 w-14 text-2xl" onClick={() => onChange(clamp(value - 1))}>
          −
        </button>
        <input
          type="number"
          inputMode="numeric"
          className="input ltr h-14 text-center text-3xl font-bold"
          value={Number.isFinite(value) ? value : ""}
          min={min}
          max={max}
          onChange={(e) => onChange(clamp(Number(e.target.value)))}
        />
        <button type="button" className="btn-soft h-14 w-14 text-2xl" onClick={() => onChange(clamp(value + 1))}>
          ＋
        </button>
      </div>
    </div>
  );
}

/** Pick a location by typing/scanning its code or tapping it in the list. */
export function LocationPicker({ locations, value, onChange }: { locations: Location[]; value: Location | null; onChange: (l: Location | null) => void }) {
  const [q, setQ] = useState("");
  const filtered = useMemo(() => {
    const n = normCode(q);
    return n ? locations.filter((l) => l.code.replace(/-/g, "").includes(n.replace(/-/g, "")) || l.code.includes(n)) : locations;
  }, [q, locations]);

  return (
    <div>
      <label className="mb-1 block text-sm text-muted">الموقع</label>
      <input
        className="input ltr text-start"
        placeholder="A-01-S2"
        value={q}
        autoCapitalize="characters"
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            const exact = locations.find((l) => l.code === normCode(q)) ?? (filtered.length === 1 ? filtered[0] : null);
            if (exact) onChange(exact);
          }
        }}
      />
      <div className="mt-2 grid max-h-56 grid-cols-2 gap-2 overflow-y-auto sm:grid-cols-3">
        {filtered.map((l) => (
          <button
            type="button"
            key={l.id}
            onClick={() => onChange(l)}
            className={`ltr rounded-2xl border px-3 py-2 text-center font-semibold ${
              value?.id === l.id ? "border-clay bg-clay text-white" : "border-line bg-white"
            }`}
          >
            {l.code}
          </button>
        ))}
        {filtered.length === 0 && <p className="col-span-full text-sm text-muted">لا يوجد موقع بهذا الرمز.</p>}
      </div>
    </div>
  );
}
