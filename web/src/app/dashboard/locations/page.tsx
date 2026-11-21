"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useAuth } from "@/components/AuthProvider";
import { Toast, useLocations, useToast } from "@/components/ui";
import { errorText, supabase } from "@/lib/supabase";
import { fmtQty } from "@/lib/format";

const pad = (n: number) => String(n).padStart(2, "0");

export default function LocationsPage() {
  const { isAdmin } = useAuth();
  const { locations, reload } = useLocations();
  const toast = useToast();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [filter, setFilter] = useState("");
  const [usage, setUsage] = useState<Record<string, { items: number; qty: number }>>({});

  // grid generator
  const [zone, setZone] = useState("A");
  const [aisles, setAisles] = useState(3);
  const [shelves, setShelves] = useState(4);
  const [bins, setBins] = useState(0);
  // single
  const [code, setCode] = useState("");
  const [desc, setDesc] = useState("");

  useEffect(() => {
    supabase
      .from("product_locations")
      .select("location_id,qty")
      .then(({ data }) => {
        const u: Record<string, { items: number; qty: number }> = {};
        for (const r of (data as { location_id: string; qty: number }[]) ?? []) {
          u[r.location_id] ??= { items: 0, qty: 0 };
          u[r.location_id].items++;
          u[r.location_id].qty += Number(r.qty);
        }
        setUsage(u);
      });
  }, [locations]);

  const shown = useMemo(() => {
    const f = filter.trim().toUpperCase();
    return f ? locations.filter((l) => l.code.includes(f) || (l.description ?? "").includes(filter.trim())) : locations;
  }, [locations, filter]);

  const preview = useMemo(() => {
    const out: string[] = [];
    const z = zone.trim().toUpperCase();
    for (let a = 1; a <= aisles; a++)
      for (let s = 1; s <= shelves; s++)
        if (bins > 0) for (let b = 1; b <= bins; b++) out.push(`${z}-${pad(a)}-S${s}-B${b}`);
        else out.push(`${z}-${pad(a)}-S${s}`);
    return out;
  }, [zone, aisles, shelves, bins]);

  async function createGrid() {
    const z = zone.trim().toUpperCase();
    if (!z) return;
    const rows = preview.map((c) => {
      const [, a, s, b] = c.split("-");
      return { code: c, zone: z, aisle: a, shelf: s, bin: b ?? null, description: `منطقة ${z} · ممر ${Number(a)} · رف ${s.slice(1)}${b ? ` · خانة ${b.slice(1)}` : ""}` };
    });
    const { error } = await supabase.from("locations").upsert(rows, { onConflict: "code", ignoreDuplicates: true });
    if (error) return toast.show(errorText(error), "error");
    toast.show(`تم إنشاء ${rows.length} موقع`);
    reload();
  }

  async function createOne(e: React.FormEvent) {
    e.preventDefault();
    const c = code.trim().toUpperCase().replace(/\s+/g, "");
    if (!c) return;
    const parts = c.split("-");
    const { error } = await supabase.from("locations").insert({
      code: c, zone: parts[0] ?? null, aisle: parts[1] ?? null, shelf: parts[2] ?? null, bin: parts[3] ?? null, description: desc.trim() || null,
    });
    if (error) return toast.show(errorText(error), "error");
    setCode("");
    setDesc("");
    toast.show(`أُضيف ${c}`);
    reload();
  }

  async function toggleActive(id: string, is_active: boolean) {
    const { error } = await supabase.from("locations").update({ is_active }).eq("id", id);
    if (error) return toast.show(errorText(error), "error");
    reload();
  }

  async function remove(id: string, c: string) {
    if (!confirm(`حذف الموقع ${c}؟`)) return;
    const { error } = await supabase.from("locations").delete().eq("id", id);
    if (error) return toast.show(errorText(error), "error");
    reload();
  }

  const toggle = (id: string) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  const labelHref = `/dashboard/labels/?codes=${encodeURIComponent(
    locations.filter((l) => selected.has(l.id)).map((l) => l.code).join(","),
  )}`;

  return (
    <div className="grid gap-5 lg:grid-cols-[1fr_340px]">
      <Toast message={toast.message} tone={toast.tone} />
      <section className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <input className="input max-w-xs" placeholder="بحث عن موقع" value={filter} onChange={(e) => setFilter(e.target.value)} />
          <button className="btn-soft" onClick={() => setSelected(new Set(shown.map((l) => l.id)))}>
            تحديد الكل
          </button>
          <button className="btn-soft" onClick={() => setSelected(new Set())}>
            إلغاء التحديد
          </button>
          <Link href={labelHref} className={`btn-primary ${selected.size ? "" : "pointer-events-none opacity-50"}`}>
            🖨️ طباعة ملصقات ({selected.size})
          </Link>
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-4">
          {shown.map((l) => {
            const u = usage[l.id];
            return (
              <div key={l.id} className={`rounded-2xl border p-3 ${selected.has(l.id) ? "border-clay bg-clay-soft" : "border-line bg-card"} ${l.is_active ? "" : "opacity-50"}`}>
                <label className="flex cursor-pointer items-center gap-2">
                  <input type="checkbox" checked={selected.has(l.id)} onChange={() => toggle(l.id)} className="h-4 w-4 accent-clay" />
                  <span className="ltr text-lg font-bold">{l.code}</span>
                </label>
                <div className="truncate text-xs text-muted">{l.description}</div>
                <div className="mt-1 text-sm">
                  {u ? (
                    <>
                      {u.items} صنف · <span className="ltr">{fmtQty(u.qty)}</span> قطعة
                    </>
                  ) : (
                    <span className="text-muted">فارغ</span>
                  )}
                </div>
                {isAdmin && (
                  <div className="mt-2 flex gap-2 text-xs">
                    <button className="rounded-lg bg-sand px-2 py-1" onClick={() => toggleActive(l.id, !l.is_active)}>
                      {l.is_active ? "تعطيل" : "تفعيل"}
                    </button>
                    {!u && (
                      <button className="rounded-lg bg-danger-soft px-2 py-1 text-danger" onClick={() => remove(l.id, l.code)}>
                        حذف
                      </button>
                    )}
                  </div>
                )}
              </div>
            );
          })}
          {shown.length === 0 && <p className="col-span-full text-muted">لا توجد مواقع بعد.</p>}
        </div>
      </section>

      <aside className="space-y-4">
        {isAdmin ? (
          <>
            <div className="card space-y-3">
              <h2 className="font-bold">إنشاء مجموعة مواقع</h2>
              <div className="grid grid-cols-2 gap-2 text-sm">
                <label>
                  المنطقة
                  <input className="input ltr" value={zone} maxLength={3} onChange={(e) => setZone(e.target.value)} />
                </label>
                <label>
                  عدد الممرات
                  <input className="input ltr" type="number" min={1} max={30} value={aisles} onChange={(e) => setAisles(Math.max(1, Number(e.target.value)))} />
                </label>
                <label>
                  رفوف لكل ممر
                  <input className="input ltr" type="number" min={1} max={20} value={shelves} onChange={(e) => setShelves(Math.max(1, Number(e.target.value)))} />
                </label>
                <label>
                  خانات لكل رف (0 = بدون)
                  <input className="input ltr" type="number" min={0} max={20} value={bins} onChange={(e) => setBins(Math.max(0, Number(e.target.value)))} />
                </label>
              </div>
              <p className="ltr text-start text-xs text-muted">
                {preview.slice(0, 3).join(", ")}
                {preview.length > 3 && ` … (${preview.length})`}
              </p>
              <button className="btn-primary w-full" onClick={createGrid} disabled={preview.length > 600}>
                إنشاء {preview.length} موقع
              </button>
            </div>
            <form className="card space-y-3" onSubmit={createOne}>
              <h2 className="font-bold">موقع واحد</h2>
              <input className="input ltr text-start" placeholder="A-03-S2-B4" value={code} onChange={(e) => setCode(e.target.value)} />
              <input className="input" placeholder="وصف (اختياري)" value={desc} onChange={(e) => setDesc(e.target.value)} />
              <button className="btn-olive w-full">إضافة</button>
            </form>
          </>
        ) : (
          <p className="card text-muted">إدارة المواقع متاحة للمدير فقط. يمكنك طباعة الملصقات.</p>
        )}
      </aside>
    </div>
  );
}
