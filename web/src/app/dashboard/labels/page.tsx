"use client";

import { Suspense, useEffect, useRef } from "react";
import { useSearchParams } from "next/navigation";
import JsBarcode from "jsbarcode";
import { useLocations } from "@/components/ui";

/** Printable shelf labels with a Code 128 barcode of the location code. */
export default function LabelsPage() {
  return (
    <Suspense fallback={null}>
      <Labels />
    </Suspense>
  );
}

function Labels() {
  const params = useSearchParams();
  const { locations } = useLocations();
  const codes = (params.get("codes") ?? "").split(",").map((c) => c.trim()).filter(Boolean);
  const byCode = new Map(locations.map((l) => [l.code, l]));

  return (
    <div>
      <div className="no-print mb-4 flex items-center gap-3">
        <button className="btn-primary" onClick={() => window.print()}>
          🖨️ طباعة
        </button>
        <span className="text-muted">{codes.length} ملصق · ورق A4، ٣ ملصقات في الصف</span>
      </div>
      <div className="grid grid-cols-3 gap-3 print:gap-2">
        {codes.map((c) => (
          <Label key={c} code={c} description={byCode.get(c)?.description ?? ""} />
        ))}
      </div>
    </div>
  );
}

function Label({ code, description }: { code: string; description: string }) {
  const svg = useRef<SVGSVGElement>(null);
  useEffect(() => {
    if (svg.current) {
      JsBarcode(svg.current, code, { format: "CODE128", height: 60, width: 2, displayValue: false, margin: 0 });
    }
  }, [code]);
  return (
    <div className="flex break-inside-avoid flex-col items-center rounded-2xl border-2 border-dashed border-line bg-white p-3 text-center print:rounded-none print:border-solid print:border-ink">
      <div className="ltr text-3xl font-bold tracking-wide">{code}</div>
      <svg ref={svg} className="my-2 h-16 w-full" />
      <div className="text-xs text-muted print:text-ink">{description}</div>
    </div>
  );
}
