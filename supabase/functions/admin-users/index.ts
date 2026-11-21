// admin-users — lets an admin create staff accounts and reset passwords from
// the dashboard without the service-role key ever reaching the browser.
// Caller must send their own access token (Authorization: Bearer <jwt>) and be
// an admin in public.profiles.
//
// Body: { action: "create", email, password, full_name, role }
//       { action: "reset_password", user_id, password }
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const URL_ = Deno.env.get("SUPABASE_URL")!;

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keys) {
    const parsed = JSON.parse(keys) as Record<string, string>;
    const first = parsed.default ?? Object.values(parsed)[0];
    if (first) return first;
  }
  throw new Error("service key not configured");
}

const admin = createClient(URL_, serviceKey(), { auth: { persistSession: false, autoRefreshToken: false } });

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json(401, { error: "not signed in" });
  const { data: who, error: whoErr } = await admin.auth.getUser(token);
  if (whoErr || !who?.user) return json(401, { error: "not signed in" });
  const { data: prof } = await admin.from("profiles").select("role").eq("id", who.user.id).single();
  if (prof?.role !== "admin") return json(403, { error: "admins only" });

  let body: Record<string, string>;
  try { body = await req.json(); } catch { return json(400, { error: "invalid JSON" }); }

  if (body.action === "create") {
    const email = String(body.email ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    const role = ["admin", "staff"].includes(body.role) ? body.role : "staff";
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json(400, { error: "invalid email" });
    if (password.length < 8) return json(400, { error: "password must be at least 8 characters" });
    const { data, error } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { full_name: body.full_name ?? "" },
    });
    if (error || !data.user) return json(400, { error: error?.message ?? "create failed" });
    // the trigger created the profile as 'pending'; apply the chosen role
    const { error: upErr } = await admin.from("profiles").update({ role, full_name: body.full_name || null }).eq("id", data.user.id);
    if (upErr) return json(500, { error: upErr.message });
    return json(200, { id: data.user.id, email, role });
  }

  if (body.action === "reset_password") {
    if (String(body.password ?? "").length < 8) return json(400, { error: "password must be at least 8 characters" });
    const { error } = await admin.auth.admin.updateUserById(String(body.user_id), { password: body.password });
    if (error) return json(400, { error: error.message });
    return json(200, { ok: true });
  }

  return json(400, { error: "unknown action" });
});
