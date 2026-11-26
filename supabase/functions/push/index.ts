// Supabase Edge Function `push`: announcements as push notifications, for
// every course site that uses this database (geog215.org, geog370.org).
//
//   { action: "key" }
//     -> { publicKey }  The VAPID public key the sites subscribe with.
//   { action: "send", course, term, title, body, url, test }
//     -> { id, devices, delivered, removed, failed }
//        Instructors only. Sends to the course's students who turned
//        notifications on (active in `term`, or in any term when it's empty)
//        and to the sender's own devices; with test: true, only to the
//        sender's own devices.
//
// Who may send is checked by the database, not here: every call is made with
// the caller's own sign-in, and admin_push_targets / admin_push_finish
// (supabase/setup.sql section 9) stop with "Instructors only." for anyone
// else. So the function needs no service-role key.
//
// Secrets (Edge Functions > Secrets in the Supabase dashboard):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY  (made on the admin page's
//   Announcements tab; see supabase/README.md)
//   VAPID_SUBJECT (optional)  mailto: or https: contact for the push services
//
// Deploy with "Verify JWT" off (the function checks sign-in itself, through
// the database), e.g. `supabase functions deploy push --no-verify-jwt`.

import { loadVapid, send, type Subscription, type Result, type Vapid } from "./webpush.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const PUBLIC_KEY = (Deno.env.get("VAPID_PUBLIC_KEY") ?? "").trim();
const PRIVATE_KEY = (Deno.env.get("VAPID_PRIVATE_KEY") ?? "").trim();
const SUBJECT = (Deno.env.get("VAPID_SUBJECT") ?? "").trim() || "https://geog215.org";

let vapid: Promise<Vapid> | null = null;

// Calls a database function as the person who called this one.
async function rpc(req: Request, fn: string, args: Record<string, unknown>) {
  const apikey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey,
      Authorization: req.headers.get("Authorization") ?? "",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  let data: unknown = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = text; }
  if (!res.ok) {
    const msg = (data && typeof data === "object" && "message" in data) ? String((data as { message: unknown }).message) : text;
    const err = new Error(msg || `${fn} failed (${res.status})`) as Error & { status: number };
    err.status = res.status === 401 || res.status === 403 ? 403 : 400;
    throw err;
  }
  return data;
}

const clean = (v: unknown, n: number) => String(v ?? "").replace(/\s+/g, " ").trim().slice(0, n);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  let input: Record<string, unknown> = {};
  try { input = await req.json(); } catch (_) { /* empty body */ }

  if (input.action === "key") {
    return json({ publicKey: PUBLIC_KEY || null });
  }

  if (input.action !== "send") return json({ error: "Unknown action." }, 400);

  if (!PUBLIC_KEY || !PRIVATE_KEY) {
    return json({ error: "not_configured", message: "VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY aren't set yet." }, 503);
  }
  try {
    vapid ??= loadVapid(PUBLIC_KEY, PRIVATE_KEY, SUBJECT);
    await vapid;
  } catch (e) {
    vapid = null;
    return json({ error: "bad_keys", message: e instanceof Error ? e.message : String(e) }, 503);
  }

  const title = clean(input.title, 120);
  const body = String(input.body ?? "").trim().slice(0, 400);
  const url = clean(input.url, 500);

  try {
    // Logs the announcement and returns where to send it (instructors only).
    const plan = await rpc(req, "admin_push_targets", {
      p_course: clean(input.course, 40), p_term: clean(input.term, 40) || null,
      p_title: title, p_body: body, p_url: url || null, p_test: input.test === true,
    }) as { id: string; targets: Subscription[] };

    const payload = JSON.stringify({ title, body, url: url || "/", tag: plan.id });
    const keys = await vapid;
    const results: Result[] = new Array(plan.targets.length);
    // A few at a time, so a big class doesn't open hundreds of connections.
    for (let i = 0; i < plan.targets.length; i += 25) {
      const batch = plan.targets.slice(i, i + 25);
      const out = await Promise.all(batch.map((t) => send(t, payload, keys)));
      out.forEach((r, j) => (results[i + j] = r));
    }
    const ok = plan.targets.filter((_, i) => results[i] === "ok").map((t) => t.endpoint);
    const gone = plan.targets.filter((_, i) => results[i] === "gone").map((t) => t.endpoint);
    const failed = results.filter((r) => r === "failed").length;

    await rpc(req, "admin_push_finish", { p_id: plan.id, p_ok: ok, p_gone: gone, p_failed: failed });
    return json({ id: plan.id, devices: plan.targets.length, delivered: ok.length, removed: gone.length, failed });
  } catch (e) {
    const status = (e as { status?: number }).status ?? 500;
    return json({ error: "send_failed", message: e instanceof Error ? e.message : String(e) }, status);
  }
});
