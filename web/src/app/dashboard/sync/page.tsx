"use client";

import { useEffect, useState } from "react";
import { STALE_MINUTES } from "@/components/ui";
import { supabase } from "@/lib/supabase";
import { fmtDateTime, minutesSince, timeAgo } from "@/lib/format";
import type { SyncRun } from "@/lib/types";

interface Issue {
  issue: "duplicate" | "odd";
  barcode_norm: string;
  barcode_raw: string | null;
  itmcode: string;
}

const STATUS: Record<SyncRun["status"], { label: string; cls: string }> = {
  ok: { label: "ناجحة", cls: "bg-olive-soft text-olive" },
  error: { label: "خطأ", cls: "bg-danger-soft text-danger" },
  running: { label: "جارية", cls: "bg-amber-soft text-amber" },
  abandoned: { label: "انقطعت", cls: "bg-sand text-muted" },
};

const sumObj = (o: Record<string, unknown> | null | undefined) =>
  Object.values(o ?? {}).reduce<number>((a, v) => a + (typeof v === "number" ? v : 0), 0);

export default function SyncPage() {
  const [runs, setRuns] = useState<SyncRun[]>([]);
  const [issues, setIssues] = useState<Issue[]>([]);

  useEffect(() => {
    const load = () =>
      supabase
        .from("sync_runs")
        .select("*")
        .order("started_at", { ascending: false })
        .limit(50)
        .then(({ data }) => setRuns((data as SyncRun[]) ?? []));
    load();
    const t = setInterval(load, 30000);
    supabase
      .from("v_barcode_issues")
      .select("issue,barcode_norm,barcode_raw,itmcode")
      .limit(200)
      .then(({ data }) => setIssues((data as Issue[]) ?? []));
    return () => clearInterval(t);
  }, []);

  const lastOk = runs.find((r) => r.status === "ok");
  const lastErr = runs.find((r) => r.status === "error");
  const m = minutesSince(lastOk?.finished_at);
  const stale = m == null || m >= STALE_MINUTES;

  return (
    <div className="space-y-5">
      <div className="grid gap-3 sm:grid-cols-3">
        <div className={`card ${stale ? "bg-danger-soft" : ""}`}>
          <div className="text-sm text-muted">آخر مزامنة ناجحة</div>
          <div className={`text-2xl font-bold ${stale ? "text-danger" : "text-olive"}`}>{timeAgo(lastOk?.finished_at)}</div>
          <div className="ltr text-start text-xs text-muted">{fmtDateTime(lastOk?.finished_at)}</div>
          {stale && <div className="mt-1 text-sm text-danger">لا مزامنة منذ أكثر من {STALE_MINUTES} دقيقة</div>}
        </div>
        <div className="card">
          <div className="text-sm text-muted">صفوف آخر مزامنة (قراءة / إرسال)</div>
          <div className="ltr text-start text-2xl font-bold">
            {sumObj(lastOk?.rows_read)} / {sumObj(lastOk?.rows_upserted)}
          </div>
          <div className="text-xs text-muted">
            {lastOk?.full_sync ? "مزامنة كاملة" : "تغييرات فقط"} · الإصدار <span className="ltr">{lastOk?.agent_version ?? "—"}</span>
          </div>
        </div>
        <div className="card">
          <div className="text-sm text-muted">آخر خطأ</div>
          <div className="text-sm text-danger">{lastErr ? lastErr.error_message : "لا توجد أخطاء"}</div>
          {lastErr && <div className="ltr text-start text-xs text-muted">{fmtDateTime(lastErr.started_at)}</div>}
        </div>
      </div>

      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[720px] text-sm">
          <thead className="bg-sand text-muted">
            <tr>
              <th className="px-3 py-2 text-start">البداية</th>
              <th className="px-3 py-2 text-start">الحالة</th>
              <th className="px-3 py-2 text-start">النوع</th>
              <th className="px-3 py-2 text-start">قراءة</th>
              <th className="px-3 py-2 text-start">إرسال</th>
              <th className="px-3 py-2 text-start">المدة</th>
              <th className="px-3 py-2 text-start">ملاحظات</th>
            </tr>
          </thead>
          <tbody>
            {runs.map((r) => (
              <tr key={r.id} className="border-t border-line align-top">
                <td className="ltr px-3 py-2 text-start">{fmtDateTime(r.started_at)}</td>
                <td className="px-3 py-2">
                  <span className={`chip ${STATUS[r.status].cls}`}>{STATUS[r.status].label}</span>
                </td>
                <td className="px-3 py-2">{r.full_sync ? "كاملة" : "تغييرات"}</td>
                <td className="ltr px-3 py-2 text-start text-xs">{JSON.stringify(r.rows_read)}</td>
                <td className="ltr px-3 py-2 text-start text-xs">{JSON.stringify(r.rows_upserted)}</td>
                <td className="ltr px-3 py-2 text-start">{r.duration_ms != null ? `${(r.duration_ms / 1000).toFixed(1)}s` : "—"}</td>
                <td className="px-3 py-2 text-xs text-danger">{r.error_message}</td>
              </tr>
            ))}
            {runs.length === 0 && (
              <tr>
                <td colSpan={7} className="px-3 py-8 text-center text-muted">
                  لم تصل أي مزامنة بعد. ثبّت برنامج المزامنة على جهاز الكاشير.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h2 className="mb-2 font-bold">ملاحظات على الباركودات ({issues.length})</h2>
        <p className="mb-3 text-sm text-muted">باركود مكرر لأكثر من صنف، أو قيمة غريبة (مسافات، طول زائد، رموز غير معتادة). تُصحَّح في سبارك تك.</p>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {issues.map((i, n) => (
            <div key={n} className="rounded-2xl border border-line bg-white px-3 py-2 text-sm">
              <span className={`chip ${i.issue === "duplicate" ? "bg-amber-soft text-amber" : "bg-clay-soft text-clay"}`}>
                {i.issue === "duplicate" ? "مكرر" : "غريب"}
              </span>{" "}
              <span className="ltr font-semibold">«{i.barcode_raw}»</span> → صنف <span className="ltr">{i.itmcode}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
