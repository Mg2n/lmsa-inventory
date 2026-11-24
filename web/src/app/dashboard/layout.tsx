"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { RequireStaff, useAuth } from "@/components/AuthProvider";
import { STALE_MINUTES, SyncBadge, useLastSync } from "@/components/ui";
import { minutesSince } from "@/lib/format";

const NAV = [
  { href: "/dashboard/", label: "الأصناف" },
  { href: "/dashboard/locations/", label: "المواقع والملصقات" },
  { href: "/dashboard/sync/", label: "المزامنة" },
  { href: "/dashboard/check/", label: "مطابقة الكمية" },
  { href: "/dashboard/daily/", label: "المراجعة اليومية", admin: true },
  { href: "/dashboard/sales/", label: "سجل المبيعات", admin: true },
  { href: "/dashboard/users/", label: "المستخدمون", admin: true },
];

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  return (
    <RequireStaff>
      <Shell>{children}</Shell>
    </RequireStaff>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  const path = usePathname();
  const { isAdmin, profile, signOut } = useAuth();
  const sync = useLastSync();
  const m = minutesSince(sync?.last_ok_at);
  const stale = sync !== null && (m == null || m >= STALE_MINUTES);

  return (
    <div className="mx-auto max-w-7xl p-4 lg:p-6">
      <header className="no-print mb-4 flex flex-wrap items-center gap-3">
        <h1 className="text-2xl font-bold">لوحة المخزون</h1>
        <SyncBadge sync={sync} />
        <div className="ms-auto flex items-center gap-2 text-sm">
          <Link href="/scan/" className="btn-soft py-2">
            الماسح
          </Link>
          <span className="hidden text-muted sm:inline">{profile?.full_name ?? profile?.email}</span>
          <button onClick={signOut} className="btn-soft py-2">
            خروج
          </button>
        </div>
      </header>

      <nav className="no-print mb-5 flex gap-2 overflow-x-auto">
        {NAV.filter((n) => !n.admin || isAdmin).map((n) => (
          <Link
            key={n.href}
            href={n.href}
            className={`whitespace-nowrap rounded-2xl px-4 py-2 font-semibold ${path === n.href ? "bg-clay text-white" : "bg-sand text-ink hover:bg-line"}`}
          >
            {n.label}
          </Link>
        ))}
      </nav>

      {stale && (
        <div className="no-print mb-4 rounded-2xl bg-danger-soft px-4 py-3 text-danger">
          ⚠️ لم تتم أي مزامنة ناجحة منذ {m == null ? "البداية" : `${m} دقيقة`}. تأكد أن جهاز الكاشير يعمل ومتصل بالإنترنت.
        </div>
      )}

      {children}
    </div>
  );
}
