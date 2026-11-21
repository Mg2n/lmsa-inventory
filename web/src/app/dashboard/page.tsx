"use client";

import { useCallback, useEffect, useState } from "react";
import { ProductCard } from "@/components/ProductCard";
import { ScanInput, Sheet, Toast, useToast } from "@/components/ui";
import { errorText, supabase } from "@/lib/supabase";
import { fmtPrice, fmtQty } from "@/lib/format";
import type { LookupResult, Product, ProductRow } from "@/lib/types";

const FILTERS = [
  { key: "all", label: "الكل" },
  { key: "no_location", label: "بدون موقع" },
  { key: "negative", label: "كمية سالبة" },
  { key: "below_reorder", label: "تحت حد الطلب" },
  { key: "mismatch", label: "غير مطابق" },
] as const;
type FilterKey = (typeof FILTERS)[number]["key"];
const PAGE = 50;

export default function ProductsPage() {
  const toast = useToast();
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState<FilterKey>("all");
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<ProductRow[]>([]);
  const [total, setTotal] = useState(0);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState<Product | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    supabase.rpc("product_counts").then(({ data }) => setCounts((data as Record<string, number>) ?? {}));
  }, [reload]);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    const t = setTimeout(async () => {
      const { data, count, error } = await supabase
        .rpc("search_products", { p_q: q || null, p_filter: filter === "all" ? null : filter }, { count: "exact" })
        .range(page * PAGE, page * PAGE + PAGE - 1);
      if (!alive) return;
      if (error) toast.show(errorText(error), "error");
      setRows((data as ProductRow[]) ?? []);
      setTotal(count ?? 0);
      setLoading(false);
    }, 250);
    return () => {
      alive = false;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, filter, page, reload]);

  const openItem = useCallback(async (itmcode: string) => {
    const { data } = await supabase.rpc("get_product", { p_itmcode: itmcode });
    if (data) setOpen(data as Product);
  }, []);

  const openCode = useCallback(
    async (code: string) => {
      const { data } = await supabase.rpc("lookup_barcode", { code });
      const r = data as LookupResult | null;
      if (r?.found) setOpen(r.products[0]);
      return !!r?.found;
    },
    [],
  );

  return (
    <div className="space-y-4">
      <Toast message={toast.message} tone={toast.tone} />
      <ScanInput
        autoFocus
        clearOnSubmit={false}
        placeholder="امسح بجهاز الباركود أو ابحث بالاسم / رقم الصنف"
        onChange={(v) => {
          setQ(v);
          setPage(0);
        }}
        onSubmit={async (v) => {
          // USB scanner sends Enter: open the exact match directly
          if (!(await openCode(v)) && rows.length === 1) openItem(rows[0].itmcode);
        }}
      />

      <div className="flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <button
            key={f.key}
            onClick={() => {
              setFilter(f.key);
              setPage(0);
            }}
            className={`chip py-2 ${filter === f.key ? "bg-ink text-cream" : "bg-sand text-ink"}`}
          >
            {f.label}
            <span className="ltr rounded-full bg-white/60 px-2 text-xs text-ink">{counts[f.key] ?? "…"}</span>
          </button>
        ))}
      </div>

      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[760px] text-start">
          <thead className="bg-sand text-sm text-muted">
            <tr>
              <th className="px-4 py-3 text-start">الصنف</th>
              <th className="px-4 py-3 text-start">رقم الصنف</th>
              <th className="px-4 py-3 text-start">السعر</th>
              <th className="px-4 py-3 text-center">الكمية</th>
              <th className="px-4 py-3 text-center">في المواقع</th>
              <th className="px-4 py-3 text-start">المواقع</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={`${r.brnid}-${r.itmcode}`} className="cursor-pointer border-t border-line hover:bg-cream" onClick={() => openItem(r.itmcode)}>
                <td className="px-4 py-3">
                  <div className="font-semibold">{r.name_ar}</div>
                  <div className="flex gap-1 text-xs">
                    {r.negative_stock && <span className="chip bg-danger-soft px-2 py-0 text-danger">سالب</span>}
                    {r.mismatch && <span className="chip bg-amber-soft px-2 py-0 text-amber">غير مطابق</span>}
                    {r.below_reorder && <span className="chip bg-clay-soft px-2 py-0 text-clay">تحت حد الطلب</span>}
                    {!r.is_active && <span className="chip bg-sand px-2 py-0 text-muted">موقوف</span>}
                  </div>
                </td>
                <td className="ltr px-4 py-3 text-start text-sm">
                  {r.itmcode}
                  <div className="text-muted">{r.barcode}</div>
                </td>
                <td className="px-4 py-3 text-sm">{fmtPrice(r.sale_price)}</td>
                <td className={`ltr px-4 py-3 text-center text-2xl font-bold ${r.negative_stock ? "text-danger" : "text-olive"}`}>{fmtQty(r.total_qty)}</td>
                <td className={`ltr px-4 py-3 text-center text-xl ${r.mismatch ? "text-amber" : ""}`}>{r.location_count ? fmtQty(r.located_qty) : "—"}</td>
                <td className="ltr px-4 py-3 text-start text-sm text-muted">{r.location_codes ?? ""}</td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-10 text-center text-muted">
                  لا توجد نتائج
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="flex items-center justify-between text-sm text-muted">
        <span>{loading ? "جارٍ التحميل…" : `${total} صنف`}</span>
        <div className="flex gap-2">
          <button className="btn-soft py-2" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>
            السابق
          </button>
          <button className="btn-soft py-2" disabled={(page + 1) * PAGE >= total} onClick={() => setPage((p) => p + 1)}>
            التالي
          </button>
        </div>
      </div>

      <Sheet open={!!open} onClose={() => setOpen(null)} title="تفاصيل الصنف">
        {open && (
          <ProductCard
            product={open}
            onChange={(p) => {
              setOpen(p);
              setReload((n) => n + 1);
            }}
            onToast={toast.show}
          />
        )}
      </Sheet>
    </div>
  );
}
