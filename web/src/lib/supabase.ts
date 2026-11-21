import { createClient } from "@supabase/supabase-js";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

export const supabase = createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: "lmsa-inventory-auth" },
});

export const FUNCTIONS_URL = `${url}/functions/v1`;

/** Readable Arabic message for a Supabase/PostgREST error. */
export function errorText(e: unknown): string {
  const msg = (e as { message?: string })?.message ?? String(e);
  if (/not allowed|permission denied|row-level security/i.test(msg)) return "ليست لديك صلاحية لهذا الإجراء";
  if (/invalid quantity/i.test(msg)) return "الكمية غير صحيحة";
  if (/not at the source/i.test(msg)) return "الصنف غير موجود في الموقع المصدر";
  if (/same/i.test(msg)) return "الموقع المصدر والهدف متطابقان";
  if (/Invalid login credentials/i.test(msg)) return "البريد أو كلمة المرور غير صحيحة";
  if (/duplicate key|already exists/i.test(msg)) return "موجود مسبقاً";
  if (/violates foreign key/i.test(msg)) return "لا يمكن الحذف: الموقع يحتوي على أصناف";
  if (/Failed to fetch|NetworkError/i.test(msg)) return "تعذّر الاتصال بالإنترنت";
  return msg;
}
