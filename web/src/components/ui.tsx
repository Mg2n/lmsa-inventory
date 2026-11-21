"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { supabase } from "@/lib/supabase";
import { minutesSince, timeAgo } from "@/lib/format";
import type { LastSync, Location } from "@/lib/types";

/** Bottom sheet on phones, centered dialog on wider screens. */
export function Sheet({ open, onClose, title, children }: { open: boolean; onClose: () => void; title: string; children: ReactNode }) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-ink/40 sm:items-center" onClick={onClose}>
      <div
        className="max-h-[90dvh] w-full max-w-lg overflow-y-auto rounded-t-3xl bg-card p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] sm:rounded-3xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-xl font-bold">{title}</h2>
          <button onClick={onClose} className="rounded-full bg-sand px-3 py-1 text-muted" aria-label="إغلاق">
            ✕
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

/**
 * Text field that works with a USB barcode scanner (keyboard wedge: types the
 * code and presses Enter) and with manual typing.
 */
export function ScanInput({
  onSubmit,
  onChange,
  placeholder = "امسح أو اكتب الباركود / رقم الصنف / الاسم",
  autoFocus = false,
  clearOnSubmit = true,
  className = "",
}: {
  onSubmit: (value: string) => void;
  onChange?: (value: string) => void;
  placeholder?: string;
  autoFocus?: boolean;
  clearOnSubmit?: boolean;
  className?: string;
}) {
  const [v, setV] = useState("");
  const ref = useRef<HTMLInputElement>(null);
  return (
    <form
      className={`flex gap-2 ${className}`}
      onSubmit={(e) => {
        e.preventDefault();
        const val = v.trim();
        if (!val) return;
        onSubmit(val);
        if (clearOnSubmit) {
          setV("");
          onChange?.("");
        }
        ref.current?.focus();
      }}
    >
      <input
        ref={ref}
        className="input"
        value={v}
        autoFocus={autoFocus}
        placeholder={placeholder}
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        enterKeyHint="search"
        onChange={(e) => {
          setV(e.target.value);
          onChange?.(e.target.value);
        }}
      />
      <button className="btn-primary shrink-0" type="submit">
        بحث
      </button>
    </form>
  );
}

export function useLastSync(pollMs = 60000) {
  const [sync, setSync] = useState<LastSync | null>(null);
  useEffect(() => {
    let alive = true;
    const load = () =>
      supabase.rpc("last_sync").then(({ data }) => {
        if (alive) setSync((data as LastSync) ?? null);
      });
    load();
    const t = setInterval(load, pollMs);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [pollMs]);
  return sync;
}

export const STALE_MINUTES = 15;

export function SyncBadge({ sync }: { sync: LastSync | null }) {
  const m = minutesSince(sync?.last_ok_at);
  const stale = m == null || m >= STALE_MINUTES;
  return (
    <span className={`chip ${stale ? "bg-danger-soft text-danger" : "bg-olive-soft text-olive"}`} title="آخر مزامنة ناجحة مع سبارك تك">
      <span className={`h-2 w-2 rounded-full ${stale ? "bg-danger" : "bg-olive"}`} />
      مزامنة: {timeAgo(sync?.last_ok_at)}
    </span>
  );
}

export function useLocations() {
  const [locations, setLocations] = useState<Location[]>([]);
  const [reloadKey, setReloadKey] = useState(0);
  useEffect(() => {
    supabase
      .from("locations")
      .select("id,code,zone,aisle,shelf,bin,description,is_active")
      .order("code")
      .then(({ data }) => setLocations((data as Location[]) ?? []));
  }, [reloadKey]);
  return { locations, reload: () => setReloadKey((k) => k + 1) };
}

export function Toast({ message, tone = "ok" }: { message: string | null; tone?: "ok" | "error" }) {
  if (!message) return null;
  return (
    <div
      className={`no-print fixed inset-x-4 top-4 z-50 mx-auto max-w-md rounded-2xl px-4 py-3 text-center font-semibold shadow-lg ${
        tone === "ok" ? "bg-olive text-white" : "bg-danger text-white"
      }`}
    >
      {message}
    </div>
  );
}

export function useToast() {
  const [state, setState] = useState<{ message: string | null; tone: "ok" | "error" }>({ message: null, tone: "ok" });
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const show = (message: string, tone: "ok" | "error" = "ok") => {
    setState({ message, tone });
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setState({ message: null, tone }), 2600);
  };
  return { ...state, show };
}
