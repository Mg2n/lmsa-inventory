"use client";

import { useEffect } from "react";

/** Phones go to the scanner, bigger screens to the dashboard. */
export default function Home() {
  useEffect(() => {
    const phone = window.matchMedia("(max-width: 820px), (pointer: coarse)").matches;
    location.replace(phone ? "/scan/" : "/dashboard/");
  }, []);
  return <div className="grid min-h-dvh place-items-center text-muted">…</div>;
}
