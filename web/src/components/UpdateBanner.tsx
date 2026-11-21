"use client";

import { useEffect, useState } from "react";

const CURRENT = process.env.NEXT_PUBLIC_BUILD_ID ?? "dev";
const CHECK_EVERY_MS = 30 * 60 * 1000;

/**
 * Registers the service worker and checks /version.json on launch, every 30
 * minutes and whenever the app comes back to the foreground. When a newer
 * deploy exists it shows a small banner; tapping it clears caches and reloads.
 */
export function UpdateBanner() {
  const [newVersion, setNewVersion] = useState<string | null>(null);

  useEffect(() => {
    if (process.env.NODE_ENV !== "production") return;
    let reg: ServiceWorkerRegistration | undefined;

    if ("serviceWorker" in navigator) {
      navigator.serviceWorker
        .register(`/sw.js?v=${encodeURIComponent(CURRENT)}`, { scope: "/" })
        .then((r) => (reg = r))
        .catch(() => {});
    }

    async function check() {
      try {
        const res = await fetch(`/version.json?t=${Date.now()}`, { cache: "no-store" });
        const { version } = (await res.json()) as { version: string };
        if (version && version !== CURRENT) setNewVersion(version);
        reg?.update().catch(() => {});
      } catch {
        /* offline: try again later */
      }
    }

    check();
    const timer = setInterval(check, CHECK_EVERY_MS);
    const onVisible = () => document.visibilityState === "visible" && check();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);

  if (!newVersion) return null;

  async function update() {
    try {
      const regs = await navigator.serviceWorker?.getRegistrations();
      await Promise.all((regs ?? []).map((r) => r.unregister()));
      const keys = await caches?.keys();
      await Promise.all((keys ?? []).map((k) => caches.delete(k)));
    } finally {
      location.reload();
    }
  }

  return (
    <button
      onClick={update}
      className="no-print fixed inset-x-3 bottom-3 z-50 mx-auto flex max-w-md items-center justify-between gap-3 rounded-2xl bg-ink px-5 py-3 text-cream shadow-lg"
    >
      <span>✨ إصدار جديد متوفر</span>
      <span className="rounded-xl bg-clay px-3 py-1 text-sm font-semibold">اضغط للتحديث</span>
    </button>
  );
}
