"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import type { Profile } from "@/lib/types";

interface AuthState {
  loading: boolean;
  session: Session | null;
  profile: Profile | null;
  isAdmin: boolean;
  isStaff: boolean;
  signOut: () => Promise<void>;
}

const Ctx = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function load(s: Session | null) {
      setSession(s);
      if (!s) {
        setProfile(null);
        setLoading(false);
        return;
      }
      const { data } = await supabase.from("profiles").select("id,email,full_name,role").eq("id", s.user.id).maybeSingle();
      if (!cancelled) {
        setProfile((data as Profile) ?? null);
        setLoading(false);
      }
    }
    supabase.auth.getSession().then(({ data }) => load(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === "SIGNED_IN" || event === "SIGNED_OUT" || event === "USER_UPDATED") load(s);
      else setSession(s);
    });
    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  const role = profile?.role;
  return (
    <Ctx.Provider
      value={{
        loading,
        session,
        profile,
        isAdmin: role === "admin",
        isStaff: role === "admin" || role === "staff",
        signOut: async () => {
          await supabase.auth.signOut();
          location.href = "/login/";
        },
      }}
    >
      {children}
    </Ctx.Provider>
  );
}

export function useAuth() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useAuth outside AuthProvider");
  return v;
}

/** Wrap a page that needs a signed-in, approved user. */
export function RequireStaff({ children, admin = false }: { children: ReactNode; admin?: boolean }) {
  const { loading, session, profile, isStaff, isAdmin, signOut } = useAuth();

  useEffect(() => {
    if (!loading && !session) location.replace("/login/");
  }, [loading, session]);

  if (loading || !session) {
    return <div className="grid min-h-dvh place-items-center text-muted">جارٍ التحميل…</div>;
  }
  if (!isStaff) {
    return (
      <div className="grid min-h-dvh place-items-center p-6">
        <div className="card max-w-sm text-center">
          <p className="text-xl font-bold">بانتظار الموافقة</p>
          <p className="mt-2 text-muted">
            تم إنشاء حسابك ({profile?.email ?? session.user.email}). اطلب من المدير تفعيل صلاحيتك.
          </p>
          <button className="btn-soft mt-5 w-full" onClick={signOut}>
            تسجيل الخروج
          </button>
        </div>
      </div>
    );
  }
  if (admin && !isAdmin) {
    return <div className="card m-6 text-center">هذه الصفحة للمدير فقط.</div>;
  }
  return <>{children}</>;
}
