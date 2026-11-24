"use client";

import { ScanLine } from "lucide-react";

import { useEffect, useState } from "react";
import { errorText, supabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";

export default function LoginPage() {
  const { session, loading } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!loading && session) location.replace("/");
  }, [loading, session]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) setError(errorText(error));
  }

  return (
    <main className="grid min-h-dvh place-items-center p-5">
      <form onSubmit={submit} className="card w-full max-w-sm space-y-4">
        <div className="text-center">
          <div className="mx-auto mb-3 grid h-16 w-16 place-items-center rounded-3xl bg-gradient-to-b from-[#cc7457] to-clay text-white shadow-[0_10px_24px_rgba(194,103,74,0.35)]">
            <ScanLine size={30} />
          </div>
          <h1 className="text-2xl font-bold">ماسح المخزون</h1>
          <p className="text-muted">سجّل الدخول للمتابعة</p>
        </div>
        <label className="block">
          <span className="mb-1 block text-sm text-muted">البريد الإلكتروني</span>
          <input className="input ltr text-start" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="block">
          <span className="mb-1 block text-sm text-muted">كلمة المرور</span>
          <input className="input ltr text-start" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        {error && <p className="rounded-2xl bg-danger-soft px-4 py-2 text-sm text-danger">{error}</p>}
        <button className="btn-primary w-full text-lg" disabled={busy}>
          {busy ? "جارٍ الدخول…" : "دخول"}
        </button>
      </form>
    </main>
  );
}
