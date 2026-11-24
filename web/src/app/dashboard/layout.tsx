"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { AlertTriangle, LogOut, Menu, ScanLine, X } from "lucide-react";
import { RequireStaff, useAuth } from "@/components/AuthProvider";
import { STALE_MINUTES, SyncBadge, useLastSync } from "@/components/ui";
import { SCANNER_LINK, visibleNav } from "@/components/nav";
import { minutesSince } from "@/lib/format";

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
  const [more, setMore] = useState(false);
  const m = minutesSince(sync?.last_ok_at);
  const stale = sync !== null && (m == null || m >= STALE_MINUTES);
  const nav = visibleNav(isAdmin);
  const current = nav.find((n) => n.href === path) ?? nav[0];
  const tabs = nav.filter((n) => n.tab).slice(0, 4);
  const CurrentIcon = current.icon;
  const who = profile?.full_name ?? profile?.email;

  return (
    <div className="mx-auto flex min-h-dvh max-w-[1500px] gap-6 p-3 pb-28 sm:p-4 sm:pb-28 lg:p-6 lg:pb-6">
      {/* sidebar (PC) */}
      <aside className="no-print sticky top-6 hidden h-[calc(100dvh-3rem)] w-64 shrink-0 flex-col rounded-3xl p-4 glass lg:flex">
        <div className="mb-6 flex items-center gap-3 px-1">
          <div className="icon-tile bg-gradient-to-b from-[#cc7457] to-clay text-white shadow-[0_6px_16px_rgba(194,103,74,0.3)]">
            <ScanLine size={20} />
          </div>
          <div>
            <div className="font-bold leading-tight">ماسح المخزون</div>
            <div className="text-xs text-muted">لوحة التحكم</div>
          </div>
        </div>
        <nav className="flex flex-col gap-1">
          {nav.map((n) => {
            const Icon = n.icon;
            const on = n.href === path;
            return (
              <Link
                key={n.href}
                href={n.href}
                className={`flex items-center gap-3 rounded-2xl px-3 py-2.5 font-semibold transition ${
                  on ? "bg-white/85 text-clay-dark shadow-[0_4px_14px_rgba(59,47,42,0.08)]" : "text-ink/80 hover:bg-white/50"
                }`}
              >
                <Icon size={19} className={on ? "text-clay" : "text-muted"} />
                {n.label}
              </Link>
            );
          })}
        </nav>
        <div className="mt-auto space-y-2">
          <Link href={SCANNER_LINK.href} className="btn-olive w-full py-2.5">
            <ScanLine size={18} /> {SCANNER_LINK.label}
          </Link>
          <div className="flex items-center justify-between gap-2 rounded-2xl bg-white/40 px-3 py-2 text-sm">
            <span className="truncate text-muted">{who}</span>
            <button onClick={signOut} className="grid h-8 w-8 place-items-center rounded-xl text-muted hover:bg-white/70 hover:text-danger" aria-label="خروج" title="خروج">
              <LogOut size={17} />
            </button>
          </div>
        </div>
      </aside>

      <div className="min-w-0 flex-1">
        {/* page header */}
        <header className="no-print mb-4 flex items-center gap-3 rounded-3xl px-4 py-3 glass lg:mb-6">
          <div className="icon-tile bg-clay-soft/80 text-clay">
            <CurrentIcon size={20} />
          </div>
          <h1 className="text-lg font-bold sm:text-xl">{current.label}</h1>
          <div className="ms-auto flex items-center gap-2">
            <SyncBadge sync={sync} />
            <Link href={SCANNER_LINK.href} className="grid h-10 w-10 place-items-center rounded-2xl bg-white/60 text-olive lg:hidden" aria-label="الماسح">
              <ScanLine size={20} />
            </Link>
          </div>
        </header>

        {stale && (
          <div className="no-print mb-4 flex items-center gap-3 rounded-3xl border border-danger/20 bg-danger-soft/80 px-4 py-3 text-danger backdrop-blur">
            <AlertTriangle size={20} className="shrink-0" />
            لم تتم أي مزامنة ناجحة منذ {m == null ? "البداية" : `${m} دقيقة`}. تأكد أن جهاز الكاشير يعمل ومتصل بالإنترنت.
          </div>
        )}

        {children}
      </div>

      {/* phone tab bar */}
      <nav className="no-print fixed inset-x-3 bottom-3 z-30 grid grid-cols-5 gap-1 rounded-3xl p-1.5 pb-[calc(0.375rem+env(safe-area-inset-bottom))] glass lg:hidden">
        {tabs.map((n) => {
          const Icon = n.icon;
          const on = n.href === path;
          return (
            <Link key={n.href} href={n.href} className={`flex flex-col items-center gap-0.5 rounded-2xl py-1.5 text-[11px] font-semibold ${on ? "bg-white/85 text-clay-dark" : "text-muted"}`}>
              <Icon size={20} className={on ? "text-clay" : ""} />
              {n.short}
            </Link>
          );
        })}
        {Array.from({ length: Math.max(0, 4 - tabs.length) }).map((_, i) => (
          <span key={i} />
        ))}
        <button onClick={() => setMore(true)} className="flex flex-col items-center gap-0.5 rounded-2xl py-1.5 text-[11px] font-semibold text-muted">
          <Menu size={20} />
          المزيد
        </button>
      </nav>

      {/* "More" sheet on phones */}
      {more && (
        <div className="no-print fixed inset-0 z-40 bg-ink/30 backdrop-blur-sm lg:hidden" onClick={() => setMore(false)}>
          <div
            className="absolute inset-x-3 bottom-3 rounded-3xl p-4 pb-[calc(1rem+env(safe-area-inset-bottom))] glass bg-white/80"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="mb-3 flex items-center justify-between">
              <span className="font-bold">القائمة</span>
              <button onClick={() => setMore(false)} className="grid h-9 w-9 place-items-center rounded-xl bg-white/70" aria-label="إغلاق">
                <X size={18} />
              </button>
            </div>
            <div className="grid grid-cols-3 gap-2">
              {[...nav, SCANNER_LINK].map((n) => {
                const Icon = n.icon;
                return (
                  <Link
                    key={n.href}
                    href={n.href}
                    onClick={() => setMore(false)}
                    className={`flex flex-col items-center gap-1.5 rounded-2xl p-3 text-center text-xs font-semibold ${n.href === path ? "bg-clay-soft text-clay-dark" : "bg-white/60"}`}
                  >
                    <Icon size={22} />
                    {n.label}
                  </Link>
                );
              })}
            </div>
            <div className="mt-3 flex items-center justify-between rounded-2xl bg-white/60 px-3 py-2 text-sm">
              <span className="truncate text-muted">{who}</span>
              <button onClick={signOut} className="flex items-center gap-1 font-semibold text-danger">
                <LogOut size={16} /> خروج
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
