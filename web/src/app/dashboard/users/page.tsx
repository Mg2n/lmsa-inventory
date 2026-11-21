"use client";

import { useEffect, useState } from "react";
import { RequireStaff, useAuth } from "@/components/AuthProvider";
import { Toast, useToast } from "@/components/ui";
import { FUNCTIONS_URL, errorText, supabase } from "@/lib/supabase";
import type { Profile, Role } from "@/lib/types";

const ROLE_LABEL: Record<Role, string> = { admin: "مدير", staff: "موظف", pending: "بانتظار الموافقة" };

async function adminCall(body: Record<string, string>) {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${FUNCTIONS_URL}/admin-users`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${data.session?.access_token ?? ""}` },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? res.statusText);
  return json;
}

export default function UsersPage() {
  return (
    <RequireStaff admin>
      <Users />
    </RequireStaff>
  );
}

function Users() {
  const { profile: me } = useAuth();
  const toast = useToast();
  const [users, setUsers] = useState<Profile[]>([]);
  const [reload, setReload] = useState(0);
  const [form, setForm] = useState({ email: "", password: "", full_name: "", role: "staff" });
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    supabase
      .from("profiles")
      .select("id,email,full_name,role,created_at")
      .order("created_at")
      .then(({ data }) => setUsers((data as Profile[]) ?? []));
  }, [reload]);

  async function setRole(id: string, role: Role) {
    const { error } = await supabase.rpc("set_user_role", { p_user_id: id, p_role: role });
    if (error) toast.show(/last admin/.test(error.message) ? "لا يمكن إزالة آخر مدير" : errorText(error), "error");
    else toast.show("تم تحديث الصلاحية");
    setReload((n) => n + 1);
  }

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      await adminCall({ action: "create", ...form });
      toast.show("تم إنشاء الحساب");
      setForm({ email: "", password: "", full_name: "", role: "staff" });
      setReload((n) => n + 1);
    } catch (err) {
      toast.show(errorText(err), "error");
    } finally {
      setBusy(false);
    }
  }

  async function resetPassword(id: string) {
    const password = prompt("كلمة المرور الجديدة (٨ أحرف على الأقل)");
    if (!password) return;
    try {
      await adminCall({ action: "reset_password", user_id: id, password });
      toast.show("تم تغيير كلمة المرور");
    } catch (err) {
      toast.show(errorText(err), "error");
    }
  }

  return (
    <div className="grid gap-5 lg:grid-cols-[1fr_340px]">
      <Toast message={toast.message} tone={toast.tone} />
      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[560px] text-sm">
          <thead className="bg-sand text-muted">
            <tr>
              <th className="px-4 py-3 text-start">الاسم</th>
              <th className="px-4 py-3 text-start">البريد</th>
              <th className="px-4 py-3 text-start">الصلاحية</th>
              <th className="px-4 py-3" />
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id} className="border-t border-line">
                <td className="px-4 py-3 font-semibold">{u.full_name}</td>
                <td className="ltr px-4 py-3 text-start">{u.email}</td>
                <td className="px-4 py-3">
                  <select
                    className="rounded-xl border border-line bg-white px-3 py-2"
                    value={u.role}
                    disabled={u.id === me?.id}
                    onChange={(e) => setRole(u.id, e.target.value as Role)}
                  >
                    {(Object.keys(ROLE_LABEL) as Role[]).map((r) => (
                      <option key={r} value={r}>
                        {ROLE_LABEL[r]}
                      </option>
                    ))}
                  </select>
                </td>
                <td className="px-4 py-3">
                  <button className="rounded-xl bg-sand px-3 py-1" onClick={() => resetPassword(u.id)}>
                    تغيير كلمة المرور
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <form className="card space-y-3" onSubmit={create}>
        <h2 className="font-bold">حساب جديد</h2>
        <input className="input" placeholder="الاسم" value={form.full_name} onChange={(e) => setForm({ ...form, full_name: e.target.value })} />
        <input className="input ltr text-start" type="email" required placeholder="email@example.com" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
        <input className="input ltr text-start" type="text" required minLength={8} placeholder="كلمة مرور مؤقتة" value={form.password} onChange={(e) => setForm({ ...form, password: e.target.value })} />
        <select className="input" value={form.role} onChange={(e) => setForm({ ...form, role: e.target.value })}>
          <option value="staff">موظف</option>
          <option value="admin">مدير</option>
        </select>
        <button className="btn-primary w-full" disabled={busy}>
          {busy ? "جارٍ الإنشاء…" : "إنشاء الحساب"}
        </button>
      </form>
    </div>
  );
}
