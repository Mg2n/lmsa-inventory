const num = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });
const money = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export const fmtQty = (n: number | null | undefined) => num.format(Number(n ?? 0));
export const fmtPrice = (n: number | null | undefined) => (n == null ? "—" : `${money.format(Number(n))} ر.س`);

export function minutesSince(iso: string | null | undefined): number | null {
  if (!iso) return null;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

export function timeAgo(iso: string | null | undefined): string {
  const m = minutesSince(iso);
  if (m == null) return "لم تتم مزامنة بعد";
  if (m < 1) return "الآن";
  if (m < 60) return `قبل ${m} دقيقة`;
  const h = Math.floor(m / 60);
  if (h < 24) return `قبل ${h} ساعة`;
  return `قبل ${Math.floor(h / 24)} يوم`;
}

export function fmtDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", { dateStyle: "short", timeStyle: "short" });
}

/** Same normalisation as private.norm_code in the database. */
export const normCode = (s: string) => s.replace(/[\s\u0000-\u001f]+/g, "").toUpperCase();

/** Haptic + audible confirmation (iPhone Safari has no vibration API, so we also beep). */
let audio: AudioContext | null = null;
export function feedback(ok = true) {
  try {
    navigator.vibrate?.(ok ? 60 : [80, 60, 80]);
  } catch {}
  try {
    audio ??= new AudioContext();
    const o = audio.createOscillator();
    const g = audio.createGain();
    o.frequency.value = ok ? 1250 : 330;
    g.gain.value = 0.08;
    o.connect(g).connect(audio.destination);
    o.start();
    o.stop(audio.currentTime + (ok ? 0.09 : 0.25));
  } catch {}
}
