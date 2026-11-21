"use client";

import { useEffect, useRef, useState } from "react";
import type { IScannerControls } from "@zxing/browser";

interface Props {
  /** Called once per detected code (debounced for repeats of the same code). */
  onDetected: (code: string) => void;
  /** When false the camera is stopped (saves battery while a result is shown). */
  active: boolean;
  className?: string;
}

const REPEAT_MS = 2500;

/**
 * Camera barcode scanner (ZXing). Reads Code 128, Code 39, EAN-13, EAN-8,
 * UPC-A and QR, including alphanumeric codes. Loaded lazily so the dashboard
 * never pays for it.
 */
export function Scanner({ onDetected, active, className = "" }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const controlsRef = useRef<IScannerControls | null>(null);
  const lastRef = useRef<{ code: string; at: number }>({ code: "", at: 0 });
  const cbRef = useRef(onDetected);
  const [error, setError] = useState<string | null>(null);
  const [torch, setTorch] = useState<boolean | null>(null);

  useEffect(() => {
    cbRef.current = onDetected;
  }, [onDetected]);

  useEffect(() => {
    if (!active) return;
    let cancelled = false;

    (async () => {
      try {
        const [{ BrowserMultiFormatReader }, { BarcodeFormat, DecodeHintType }] = await Promise.all([
          import("@zxing/browser"),
          import("@zxing/library"),
        ]);
        const hints = new Map();
        hints.set(DecodeHintType.POSSIBLE_FORMATS, [
          BarcodeFormat.CODE_128,
          BarcodeFormat.CODE_39,
          BarcodeFormat.EAN_13,
          BarcodeFormat.EAN_8,
          BarcodeFormat.UPC_A,
          BarcodeFormat.QR_CODE,
        ]);
        hints.set(DecodeHintType.TRY_HARDER, true);
        const reader = new BrowserMultiFormatReader(hints, { delayBetweenScanAttempts: 120 });
        if (cancelled || !videoRef.current) return;

        const controls = await reader.decodeFromConstraints(
          {
            audio: false,
            video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 }, height: { ideal: 720 } },
          },
          videoRef.current,
          (result) => {
            if (!result) return;
            const code = result.getText();
            const now = Date.now();
            if (code === lastRef.current.code && now - lastRef.current.at < REPEAT_MS) return;
            lastRef.current = { code, at: now };
            cbRef.current(code);
          },
        );
        if (cancelled) {
          controls.stop();
          return;
        }
        controlsRef.current = controls;
        setTorch(controls.switchTorch ? false : null);
        setError(null);
      } catch (e) {
        const name = (e as Error)?.name;
        setError(
          name === "NotAllowedError"
            ? "لم يُسمح باستخدام الكاميرا. فعّل الإذن من إعدادات المتصفح، أو أدخل الرمز يدوياً."
            : "تعذّر تشغيل الكاميرا. أدخل الرمز يدوياً.",
        );
      }
    })();

    return () => {
      cancelled = true;
      controlsRef.current?.stop();
      controlsRef.current = null;
    };
  }, [active]);

  async function toggleTorch() {
    const c = controlsRef.current;
    if (!c?.switchTorch) return;
    const next = !torch;
    await c.switchTorch(next).catch(() => {});
    setTorch(next);
  }

  return (
    <div className={`relative overflow-hidden rounded-3xl bg-ink ${className}`}>
      <video ref={videoRef} className="h-full w-full object-cover" muted playsInline autoPlay />
      {/* aiming frame */}
      <div className="pointer-events-none absolute inset-0 grid place-items-center">
        <div className="h-1/3 w-4/5 rounded-2xl border-4 border-cream/80 shadow-[0_0_0_2000px_rgba(59,47,42,0.35)]" />
      </div>
      {torch !== null && (
        <button
          onClick={toggleTorch}
          className="absolute left-3 top-3 rounded-full bg-cream/90 px-3 py-2 text-sm font-semibold text-ink"
        >
          {torch ? "إطفاء الضوء" : "🔦 ضوء"}
        </button>
      )}
      {!active && (
        <div className="absolute inset-0 grid place-items-center bg-ink/60 text-cream">الكاميرا متوقفة</div>
      )}
      {error && (
        <div className="absolute inset-x-3 bottom-3 rounded-2xl bg-cream p-3 text-center text-sm text-danger">{error}</div>
      )}
    </div>
  );
}
