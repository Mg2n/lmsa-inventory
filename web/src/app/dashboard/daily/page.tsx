"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { RequireStaff } from "@/components/AuthProvider";
import { Toast, useToast } from "@/components/ui";
import { errorText, supabase } from "@/lib/supabase";
import { fmtPrice, fmtQty } from "@/lib/format";

interface DayBranch {
  brnid: string;
  whsno: string;
  name: string | null;
  sales_net: number;
  sales_bills: number;
  returns_net: number;
  return_bills: number;
  qty: number;
  discount: number;
  cancelled: number;
  first_at: string | null;
  last_at: string | null;
  review: { by: string | null; at: string; note: string | null } | null;
}

const TZ = "Asia/Riyadh";
const storeDay = (d: Date) =>
  new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
function addDays(day: string, n: number) {
  const d = new Date(`${day}T12:00:00+03:00`);
  d.setUTCDate(d.getUTCDate() + n);
  return storeDay(d);
}
const fmtTime = (iso: string | null) =>
  iso ? new Date(iso).toLocaleTimeString("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }) : "—";
const dayLabel = (day: string) =>
  new Date(`${day}T12:00:00+03:00`).toLocaleDateString("ar-SA-u-ca-gregory", { timeZone: TZ, weekday: "long", day: "numeric", month: "long", year: "numeric" });

export default function DailyPage() {
  return (
    <RequireStaff admin>
      <Daily />
    </RequireStaff>
  );
}

function Daily() {
  const today = storeDay(new Date());
  const [day, setDay] = useState(today);
  const [rows, setRows] = useState<DayBranch[] | null>(null);
  const [busy, setBusy] = useState(false);
  const toast = useToast();

  const load = useCallback(async () => {
    setBusy(true);
    const { data, error } = await supabase.rpc("sales_daily", { p_day: day });
    setBusy(false);
    if (error) return toast.show(errorText(error), "error");
    setRows((data as DayBranch[]) ?? []);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [day]);

  useEffect(() => {
    load();
  }, [load]);

  async function setReviewed(r: DayBranch, reviewed: boolean) {
    const note = reviewed ? prompt("ملاحظة على مراجعة اليوم (اختياري)") ?? "" : "";
    const { error } = await supabase.rpc("set_day_review", { p_brnid: r.brnid, p_whsno: r.whsno, p_day: day, p_reviewed: reviewed, p_note: note });
    if (error) return toast.show(errorText(error), "error");
    toast.show(reviewed ? "تم تسجيل المراجعة" : "أُلغيت المراجعة");
    load();
  }

  // net = sales minus returns (returns are stored as positive amounts on document type 108)
  const net = (r: DayBranch) => Number(r.sales_net) - Number(r.returns_net);
  const total = (rows ?? []).reduce((a, r) => a + net(r), 0);
  const reviewed = (rows ?? []).filter((r) => r.review).length;

  return (
    <div className="space-y-4">
      <Toast message={toast.message} tone={toast.tone} />
      <div className="card flex flex-wrap items-center gap-3">
        <button className="btn-soft" onClick={() => setDay(addDays(day, -1))} aria-label="اليوم السابق">
          → السابق
        </button>
        <input type="date" className="input ltr w-auto" value={day} max={today} onChange={(e) => e.target.value && setDay(e.target.value)} />
        <button className="btn-soft" disabled={day >= today} onClick={() => setDay(addDays(day, 1))} aria-label="اليوم التالي">
          التالي ←
        </button>
        {day !== today && (
          <button className="btn-soft" onClick={() => setDay(today)}>
            اليوم
          </button>
        )}
        <div className="ms-auto text-start">
          <div className="font-bold">{dayLabel(day)}</div>
          <div className="text-sm text-muted">
            صافي اليوم بعد المرتجعات <b className="ltr text-ink">{fmtPrice(total)}</b> · تمت مراجعة {reviewed} من {rows?.length ?? 0}
          </div>
        </div>
      </div>

      {busy && !rows && <p className="card text-muted">جارٍ التحميل…</p>}
      {rows && rows.length === 0 && <p className="card text-center text-muted">لا توجد فواتير في هذا اليوم.</p>}

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {(rows ?? []).map((r) => (
          <div key={`${r.brnid}|${r.whsno}`} className={`card space-y-3 ${r.review ? "border-olive" : ""}`}>
            <div className="flex items-start justify-between gap-2">
              <div>
                <div className="text-lg font-bold">{r.name ?? `مستودع ${r.whsno}`}</div>
                <div className="text-sm text-muted">
                  مستودع <span className="ltr">{r.whsno}</span> · من <span className="ltr">{fmtTime(r.first_at)}</span> إلى{" "}
                  <span className="ltr">{fmtTime(r.last_at)}</span>
                </div>
              </div>
              {r.review ? <span className="chip bg-olive-soft text-olive">✓ تمت المراجعة</span> : <span className="chip bg-amber-soft text-amber">بانتظار المراجعة</span>}
            </div>

            <div className="rounded-3xl bg-olive-soft p-4 text-center">
              <div className="text-sm text-muted">الصافي بعد المرتجعات (شامل الضريبة)</div>
              <div className="ltr text-4xl font-bold text-olive">{fmtPrice(net(r))}</div>
              <div className="mt-1 text-sm text-muted">
                مبيعات <b className="ltr text-ink">{fmtPrice(r.sales_net)}</b>
                {" − "}مرتجعات <b className={`ltr ${Number(r.returns_net) ? "text-danger" : "text-ink"}`}>{fmtPrice(r.returns_net)}</b>
              </div>
            </div>
            <div className="grid grid-cols-3 gap-2 text-center text-sm">
              <div className="rounded-2xl bg-sand p-2">
                <div className="text-muted">فواتير</div>
                <div className="ltr text-xl font-bold">{fmtQty(r.sales_bills)}</div>
              </div>
              <div className="rounded-2xl bg-sand p-2">
                <div className="text-muted">قطع</div>
                <div className="ltr text-xl font-bold">{fmtQty(r.qty)}</div>
              </div>
              <div className={`rounded-2xl p-2 ${r.return_bills ? "bg-danger-soft" : "bg-sand"}`}>
                <div className="text-muted">مرتجعات</div>
                <div className={`ltr text-xl font-bold ${r.return_bills ? "text-danger" : ""}`}>{fmtQty(r.return_bills)}</div>
              </div>
            </div>
            {(Number(r.discount) > 0 || r.cancelled > 0 || r.return_bills > 0) && (
              <div className="flex flex-wrap gap-2 text-xs">
                {Number(r.discount) > 0 && <span className="chip bg-sand text-muted">خصومات <b className="ltr">{fmtPrice(r.discount)}</b></span>}
                {r.return_bills > 0 && <span className="chip bg-danger-soft text-danger">قيمة المرتجعات <b className="ltr">{fmtPrice(r.returns_net)}</b></span>}
                {r.cancelled > 0 && <span className="chip bg-sand text-muted">ملغاة <b className="ltr">{r.cancelled}</b></span>}
              </div>
            )}
            {r.review && (
              <p className="text-xs text-muted">
                راجعها {r.review.by ?? "—"} · <span className="ltr">{new Date(r.review.at).toLocaleString("en-GB", { timeZone: TZ, dateStyle: "short", timeStyle: "short" })}</span>
                {r.review.note && <> — {r.review.note}</>}
              </p>
            )}
            <div className="grid grid-cols-2 gap-2">
              <Link href={`/dashboard/sales/?day=${day}&whs=${encodeURIComponent(r.whsno)}`} className="btn-soft">
                كل فواتير اليوم
              </Link>
              {r.review ? (
                <button className="btn-soft" onClick={() => setReviewed(r, false)}>
                  إلغاء المراجعة
                </button>
              ) : (
                <button className="btn-primary" onClick={() => setReviewed(r, true)}>
                  ✓ تمت المراجعة
                </button>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
