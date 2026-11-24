"use client";

import { useCallback, useEffect, useState } from "react";
import { Package, Receipt, ShoppingBag, TrendingUp, Undo2, Wallet, type LucideIcon } from "lucide-react";
import { RequireStaff } from "@/components/AuthProvider";
import { ScanInput } from "@/components/ui";
import { errorText, supabase } from "@/lib/supabase";
import { fmtPrice, fmtQty } from "@/lib/format";
import type { LookupResult } from "@/lib/types";

interface SaleLine {
  invserial: string;
  itmcode: string;
  name_ar: string | null;
  saleqty: number | null;
  unitprice: number | null;
  discamt: number | null;
  taxamt: number | null;
  itmtotal: number | null;
  cost: number | null;
  profit: number | null;
}
interface Bill {
  brnid: string;
  gltype: string;
  vouno: string;
  voudate: string | null;
  whsno: string | null;
  whs_name: string | null;
  posno: string | null;
  sellerno: string | null;
  userno: string | null;
  shiftno: string | null;
  invqty: number | null;
  invtotal: number | null;
  disctotal: number | null;
  taxtotal: number | null;
  invnetamt: number | null;
  cost: number | null;
  profit: number | null;
  is_active: boolean;
  lines: SaleLine[];
}
interface SalesResult {
  total: number;
  sums: {
    sales_net: number;
    returns_net: number;
    sales_bills: number;
    return_bills: number;
    qty: number;
    cost: number | null;
    profit: number | null;
    revenue_ex_tax: number | null;
  };
  bills: Bill[];
}

const TZ = "Asia/Riyadh"; // Spark Tech stores bill times in store time (UTC+3, no daylight saving)
const PAGE = 50;

const DOC: Record<string, { label: string; cls: string }> = {
  "104": { label: "فاتورة بيع", cls: "bg-olive-soft text-olive" },
  "108": { label: "مرتجع", cls: "bg-danger-soft text-danger" },
};
const docOf = (t: string) => DOC[t] ?? { label: `مستند ${t}`, cls: "bg-sand text-muted" };

/** YYYY-MM-DD for a date in store time */
function storeDay(d: Date) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
const dayStart = (day: string) => `${day}T00:00:00+03:00`;
function addDays(day: string, n: number) {
  const d = new Date(`${day}T12:00:00+03:00`);
  d.setUTCDate(d.getUTCDate() + n);
  return storeDay(d);
}
const fmtTime = (iso: string | null) =>
  iso ? new Date(iso).toLocaleTimeString("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }) : "—";
const fmtDay = (iso: string | null) =>
  iso ? new Date(iso).toLocaleDateString("en-GB", { timeZone: TZ, day: "2-digit", month: "2-digit", year: "numeric" }) : "—";

type Preset = "today" | "yesterday" | "7d" | "month" | "custom";

export default function SalesPage() {
  return (
    <RequireStaff admin>
      <Sales />
    </RequireStaff>
  );
}

function Sales() {
  const today = storeDay(new Date());
  const [preset, setPreset] = useState<Preset>("today");
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(today); // inclusive
  const [whsno, setWhsno] = useState("");
  const [gltype, setGltype] = useState("");
  const [item, setItem] = useState<{ itmcode: string; name: string | null } | null>(null);
  const [warehouses, setWarehouses] = useState<{ whsno: string; name: string | null }[]>([]);
  const [data, setData] = useState<SalesResult | null>(null);
  const [bills, setBills] = useState<Bill[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // opened from the daily review: ?day=YYYY-MM-DD&whs=3
  useEffect(() => {
    const q = new URLSearchParams(window.location.search);
    const d = q.get("day");
    if (d && /^\d{4}-\d{2}-\d{2}$/.test(d)) { setPreset("custom"); setFrom(d); setTo(d); }
    const w = q.get("whs");
    if (w) setWhsno(w);
  }, []);

  useEffect(() => {
    supabase.rpc("sales_warehouses").then(({ data }) => setWarehouses((data as { whsno: string; name: string | null }[]) ?? []));
  }, []);

  function applyPreset(p: Preset) {
    setPreset(p);
    if (p === "today") { setFrom(today); setTo(today); }
    if (p === "yesterday") { const y = addDays(today, -1); setFrom(y); setTo(y); }
    if (p === "7d") { setFrom(addDays(today, -6)); setTo(today); }
    if (p === "month") { setFrom(today.slice(0, 8) + "01"); setTo(today); }
  }

  const load = useCallback(
    async (offset: number) => {
      setBusy(true);
      setError(null);
      const { data, error } = await supabase.rpc("sales_bills", {
        p_from: dayStart(from),
        p_to: dayStart(addDays(to, 1)),
        p_whsno: whsno || null,
        p_itmcode: item?.itmcode ?? null,
        p_gltype: gltype || null,
        p_limit: PAGE,
        p_offset: offset,
      });
      setBusy(false);
      if (error) return setError(errorText(error));
      const r = data as SalesResult;
      setData(r);
      setBills((prev) => (offset === 0 ? r.bills : [...prev, ...r.bills]));
    },
    [from, to, whsno, gltype, item],
  );

  useEffect(() => {
    load(0);
  }, [load]);

  async function pickItem(code: string) {
    const { data } = await supabase.rpc("lookup_barcode", { code });
    const r = data as LookupResult;
    if (r?.found) setItem({ itmcode: r.products[0].itmcode, name: r.products[0].name_ar });
    else setItem({ itmcode: code.trim(), name: null });
  }

  const s = data?.sums;
  const whName = (w: string | null, n: string | null) => (n ? `${n}` : w ? `مستودع ${w}` : "—");

  return (
    <div className="space-y-4">
      {/* filters */}
      <div className="card space-y-3">
        <div className="flex flex-wrap gap-2">
          {([["today", "اليوم"], ["yesterday", "أمس"], ["7d", "آخر ٧ أيام"], ["month", "هذا الشهر"], ["custom", "تاريخ محدد"]] as [Preset, string][]).map(([p, l]) => (
            <button key={p} onClick={() => applyPreset(p)} className={`rounded-2xl px-4 py-2 font-semibold ${preset === p ? "bg-clay text-white" : "bg-sand"}`}>
              {l}
            </button>
          ))}
        </div>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {preset === "custom" && (
            <>
              <label className="text-sm text-muted">
                من
                <input type="date" className="input ltr mt-1" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
              </label>
              <label className="text-sm text-muted">
                إلى
                <input type="date" className="input ltr mt-1" value={to} min={from} onChange={(e) => setTo(e.target.value)} />
              </label>
            </>
          )}
          <label className="text-sm text-muted">
            الفرع / المستودع
            <select className="input mt-1" value={whsno} onChange={(e) => setWhsno(e.target.value)}>
              <option value="">الكل</option>
              {warehouses.map((w) => (
                <option key={w.whsno} value={w.whsno}>
                  {w.whsno} — {w.name ?? `مستودع ${w.whsno}`}
                </option>
              ))}
            </select>
          </label>
          <label className="text-sm text-muted">
            نوع المستند
            <select className="input mt-1" value={gltype} onChange={(e) => setGltype(e.target.value)}>
              <option value="">الكل</option>
              <option value="104">فواتير البيع</option>
              <option value="108">المرتجعات</option>
            </select>
          </label>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          <div className="min-w-[260px] flex-1">
            <ScanInput onSubmit={pickItem} placeholder="صنف معيّن: امسح أو اكتب الباركود / رقم الصنف" />
          </div>
          {item && (
            <span className="chip bg-clay-soft text-clay-dark">
              {item.name ?? "صنف"} <b className="ltr">{item.itmcode}</b>
              <button className="ms-1 font-bold" onClick={() => setItem(null)} aria-label="إزالة">
                ✕
              </button>
            </span>
          )}
        </div>
      </div>

      {/* totals */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <Stat icon={Wallet} label="الصافي بعد المرتجعات" value={s ? fmtPrice(Number(s.sales_net) - Number(s.returns_net)) : "—"} tone="olive" />
        {s && s.profit != null ? (
          <Stat
            icon={TrendingUp}
            label="الربح (قبل الضريبة)"
            value={`${fmtPrice(s.profit)}${s.revenue_ex_tax ? ` · ${Math.round((100 * Number(s.profit)) / Number(s.revenue_ex_tax))}%` : ""}`}
            tone="clay"
          />
        ) : (
          <Stat icon={ShoppingBag} label="المبيعات (شامل الضريبة)" value={s ? fmtPrice(s.sales_net) : "—"} />
        )}
        <Stat icon={Receipt} label="عدد فواتير البيع" value={s ? fmtQty(s.sales_bills) : "—"} />
        <Stat icon={Package} label="القطع المباعة" value={s ? fmtQty(s.qty) : "—"} />
        <Stat icon={Undo2} label="المرتجعات" value={s ? `${fmtQty(s.return_bills)} · ${fmtPrice(s.returns_net)}` : "—"} tone={s && s.return_bills ? "danger" : undefined} />
      </div>

      {error && <p className="card text-danger">{error}</p>}

      {/* bills */}
      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[760px] text-sm">
          <thead className="bg-sand text-muted">
            <tr>
              <th className="px-3 py-2 text-start">الوقت</th>
              <th className="px-3 py-2 text-start">المستند</th>
              <th className="px-3 py-2 text-start">رقم</th>
              <th className="px-3 py-2 text-start">الفرع / المستودع</th>
              <th className="px-3 py-2 text-start">نقطة البيع</th>
              <th className="px-3 py-2 text-start">القطع</th>
              <th className="px-3 py-2 text-start">الصافي</th>
            </tr>
          </thead>
          <tbody>
            {bills.map((b) => {
              const key = `${b.brnid}|${b.gltype}|${b.vouno}`;
              const isOpen = open === key;
              const d = docOf(b.gltype);
              return (
                <BillRows key={key} bill={b} doc={d} isOpen={isOpen} onToggle={() => setOpen(isOpen ? null : key)} whName={whName(b.whsno, b.whs_name)} highlight={item?.itmcode} />
              );
            })}
            {!busy && bills.length === 0 && (
              <tr>
                <td colSpan={7} className="px-3 py-10 text-center text-muted">
                  لا توجد فواتير في هذه الفترة.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="flex items-center justify-between text-sm text-muted">
        <span>
          {data ? `${fmtQty(bills.length)} من ${fmtQty(data.total)} مستند` : ""} {busy && "· جارٍ التحميل…"}
        </span>
        {data && bills.length < data.total && (
          <button className="btn-soft" disabled={busy} onClick={() => load(bills.length)}>
            عرض المزيد
          </button>
        )}
      </div>
    </div>
  );
}

const TONE = {
  olive: { tile: "bg-olive-soft text-olive", text: "text-olive" },
  clay: { tile: "bg-clay-soft text-clay", text: "text-clay-dark" },
  danger: { tile: "bg-danger-soft text-danger", text: "text-danger" },
  none: { tile: "bg-sand text-muted", text: "" },
};

function Stat({ icon: Icon, label, value, tone }: { icon: LucideIcon; label: string; value: string; tone?: "olive" | "clay" | "danger" }) {
  const t = TONE[tone ?? "none"];
  return (
    <div className="card flex items-center gap-3 p-4">
      <div className={`icon-tile ${t.tile}`}>
        <Icon size={20} />
      </div>
      <div className="min-w-0">
        <div className="truncate text-sm text-muted">{label}</div>
        <div className={`ltr text-start text-xl font-bold ${t.text}`}>{value}</div>
      </div>
    </div>
  );
}

function BillRows({
  bill: b,
  doc,
  isOpen,
  onToggle,
  whName,
  highlight,
}: {
  bill: Bill;
  doc: { label: string; cls: string };
  isOpen: boolean;
  onToggle: () => void;
  whName: string;
  highlight?: string;
}) {
  return (
    <>
      <tr className={`cursor-pointer border-t border-line hover:bg-sand/50 ${b.is_active ? "" : "opacity-50"}`} onClick={onToggle}>
        <td className="ltr px-3 py-2 text-start">
          <b>{fmtTime(b.voudate)}</b> <span className="text-muted">{fmtDay(b.voudate)}</span>
        </td>
        <td className="px-3 py-2">
          <span className={`chip ${doc.cls}`}>{doc.label}</span>
          {!b.is_active && <span className="chip ms-1 bg-sand text-muted">ملغى</span>}
        </td>
        <td className="ltr px-3 py-2 text-start font-semibold">{b.vouno}</td>
        <td className="px-3 py-2">{whName}</td>
        <td className="ltr px-3 py-2 text-start">{b.posno ?? "—"}</td>
        <td className="ltr px-3 py-2 text-start">{fmtQty(b.invqty)}</td>
        <td className="ltr px-3 py-2 text-start font-bold">{fmtPrice(b.invnetamt)}</td>
      </tr>
      {isOpen && (
        <tr className="bg-cream">
          <td colSpan={7} className="px-3 pb-4 pt-1">
            <div className="mb-2 flex flex-wrap gap-2 text-xs text-muted">
              <span className="chip bg-sand">البائع <b className="ltr">{b.sellerno ?? "—"}</b></span>
              <span className="chip bg-sand">المستخدم <b className="ltr">{b.userno ?? "—"}</b></span>
              <span className="chip bg-sand">الوردية <b className="ltr">{b.shiftno ?? "—"}</b></span>
              <span className="chip bg-sand">قبل الضريبة <b className="ltr">{fmtPrice(b.invtotal)}</b></span>
              <span className="chip bg-sand">الخصم <b className="ltr">{fmtPrice(b.disctotal)}</b></span>
              <span className="chip bg-sand">الضريبة <b className="ltr">{fmtPrice(b.taxtotal)}</b></span>
              {b.profit != null && (
                <span className="chip bg-clay-soft text-clay-dark">
                  <TrendingUp size={13} /> الربح <b className="ltr">{fmtPrice(b.profit)}</b>
                </span>
              )}
            </div>
            <table className="w-full text-sm">
              <thead className="text-muted">
                <tr>
                  <th className="py-1 text-start">الصنف</th>
                  <th className="py-1 text-start">الكمية</th>
                  <th className="py-1 text-start">السعر قبل الضريبة</th>
                  <th className="py-1 text-start">الخصم</th>
                  <th className="py-1 text-start">الضريبة</th>
                  <th className="py-1 text-start">الإجمالي</th>
                  {b.profit != null && <th className="py-1 text-start">الربح</th>}
                </tr>
              </thead>
              <tbody>
                {b.lines.map((l) => (
                  <tr key={l.invserial} className={`border-t border-line ${highlight && l.itmcode.toUpperCase() === highlight.toUpperCase() ? "bg-clay-soft" : ""}`}>
                    <td className="py-1">
                      {l.name_ar ?? "—"} <span className="ltr text-muted">{l.itmcode}</span>
                    </td>
                    <td className="ltr py-1 text-start">{fmtQty(l.saleqty)}</td>
                    <td className="ltr py-1 text-start">{fmtPrice(l.unitprice)}</td>
                    <td className="ltr py-1 text-start">{fmtPrice(l.discamt)}</td>
                    <td className="ltr py-1 text-start">{fmtPrice(l.taxamt)}</td>
                    <td className="ltr py-1 text-start font-semibold">{fmtPrice(l.itmtotal)}</td>
                    {b.profit != null && <td className="ltr py-1 text-start text-clay-dark">{l.profit == null ? "—" : fmtPrice(l.profit)}</td>}
                  </tr>
                ))}
                {b.lines.length === 0 && (
                  <tr>
                    <td colSpan={7} className="py-2 text-muted">
                      لم تصل أسطر هذه الفاتورة بعد.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </td>
        </tr>
      )}
    </>
  );
}
