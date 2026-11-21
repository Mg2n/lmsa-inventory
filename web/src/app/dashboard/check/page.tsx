"use client";

import { useState } from "react";
import { ScanInput } from "@/components/ui";
import { supabase } from "@/lib/supabase";
import { fmtQty } from "@/lib/format";
import type { LookupResult, Product, StockRow } from "@/lib/types";

const COLS: [keyof StockRow, string, "+" | "-"][] = [
  ["beginqty", "BEGINQTY", "+"],
  ["purchqty", "PURCHQTY", "+"],
  ["saleqty", "SALEQTY", "-"],
  ["purchrtn", "PURCHRTN", "-"],
  ["salertn", "SALERTN", "+"],
  ["inqty", "INQTY", "+"],
  ["outqty", "OUTQTY", "-"],
];

/**
 * Verifies the stock formula: shows the computed quantity next to the raw
 * ITEMSMASTER columns so it can be compared with the Spark Tech screen.
 */
export default function CheckPage() {
  const [product, setProduct] = useState<Product | null>(null);
  const [rows, setRows] = useState<StockRow[]>([]);
  const [spark, setSpark] = useState("");
  const [notFound, setNotFound] = useState(false);

  async function load(code: string) {
    setSpark("");
    const { data } = await supabase.rpc("lookup_barcode", { code });
    const r = data as LookupResult;
    if (!r?.found) {
      setProduct(null);
      setRows([]);
      setNotFound(true);
      return;
    }
    setNotFound(false);
    const p = r.products[0];
    setProduct(p);
    const s = await supabase.from("erp_stock").select("*").eq("itmcode", p.itmcode).order("whsno").order("batchno");
    setRows((s.data as StockRow[]) ?? []);
  }

  const total = rows.reduce((a, r) => a + Number(r.qty_computed), 0);
  const diff = spark.trim() === "" ? null : Number(spark) - total;

  return (
    <div className="space-y-4">
      <div className="card space-y-2">
        <h2 className="font-bold">التحقق من معادلة الكمية</h2>
        <p className="ltr text-start text-sm text-muted">
          qty = BEGINQTY + PURCHQTY − SALEQTY − PURCHRTN + SALERTN + INQTY − OUTQTY &nbsp;(RESERVQTY shown separately)
        </p>
        <p className="text-sm text-muted">القيم هي مجموع صفوف ITEMSMASTER لكل مستودع. افتح نفس الصنف في سبارك تك، واكتب الكمية الظاهرة هناك للمقارنة. جرّب عدة أصناف قبل الاعتماد على الرقم.</p>
        <ScanInput onSubmit={load} placeholder="امسح أو اكتب باركود / رقم صنف" autoFocus />
      </div>

      {notFound && <p className="card text-danger">غير موجود في سبارك تك</p>}

      {product && (
        <div className="card space-y-4">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h3 className="text-xl font-bold">{product.name_ar}</h3>
            <span className="ltr text-muted">{product.itmcode}</span>
          </div>
          <div className="overflow-x-auto">
            <table className="ltr w-full min-w-[760px] text-sm">
              <thead className="bg-sand text-muted">
                <tr>
                  <th className="px-2 py-2 text-left">WHSNO</th>
                  <th className="px-2 py-2 text-left">BATCHNO</th>
                  {COLS.map(([, h, sign]) => (
                    <th key={h} className="px-2 py-2 text-right">
                      {sign}
                      {h}
                    </th>
                  ))}
                  <th className="px-2 py-2 text-right">RESERVQTY</th>
                  <th className="px-2 py-2 text-right">= qty</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={`${r.whsno}-${r.batchno}`} className="border-t border-line">
                    <td className="px-2 py-1">{r.whsno}</td>
                    <td className="px-2 py-1">{r.batchno || "—"}</td>
                    {COLS.map(([k]) => (
                      <td key={k} className={`px-2 py-1 text-right ${Number(r[k]) ? "font-semibold" : "text-muted"}`}>
                        {fmtQty(Number(r[k]))}
                      </td>
                    ))}
                    <td className="px-2 py-1 text-right">{fmtQty(r.reserved_qty)}</td>
                    <td className="px-2 py-1 text-right font-bold">{fmtQty(r.qty_computed)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="grid gap-3 sm:grid-cols-3">
            <div className="rounded-3xl bg-olive-soft p-4 text-center">
              <div className="text-sm text-muted">المحسوبة</div>
              <div className="ltr text-5xl font-bold text-olive">{fmtQty(total)}</div>
            </div>
            <label className="rounded-3xl bg-sand p-4 text-center">
              <div className="text-sm text-muted">الظاهرة في سبارك تك</div>
              <input className="input ltr mt-1 text-center text-3xl font-bold" inputMode="decimal" value={spark} onChange={(e) => setSpark(e.target.value)} />
            </label>
            <div className={`rounded-3xl p-4 text-center ${diff == null ? "bg-sand" : diff === 0 ? "bg-olive-soft" : "bg-danger-soft"}`}>
              <div className="text-sm text-muted">الفرق</div>
              <div className="ltr text-5xl font-bold">{diff == null ? "—" : diff === 0 ? "✓" : fmtQty(diff)}</div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
