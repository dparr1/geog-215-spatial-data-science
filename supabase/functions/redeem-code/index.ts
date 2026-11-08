// GEOG 215: set up (or reset) a student's password from their setup code.
//
// Called by the sign-in gate (assets/auth-gate.html) when a student uses
// "First time here?". It receives { email, code, password } and:
//   - email and code belong to the same active roster row, not set up yet:
//     creates a Supabase account with that email and password, already
//     confirmed (so Supabase never sends an email), and links it to the row;
//   - already set up, with roster.allow_reset = true: sets the new password
//     and turns allow_reset back off;
//   - anything else: refuses.
// The student then signs in with email + password from the browser.
//
// Deploy with JWT verification OFF (students aren't signed in yet):
//   supabase functions deploy redeem-code --no-verify-jwt
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided to every Edge
// Function automatically; nothing to configure. See supabase/README.md.

import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const ALLOWED_ORIGINS = ["https://geog215.org", "https://www.geog215.org"];
const MIN_PASSWORD = 8;
const MAX_PASSWORD = 72; // bcrypt limit used by Supabase Auth
// A code reserved by a request that then failed is free again after this long.
const STALE_RESERVATION_MS = 2 * 60 * 1000;

function corsHeaders(origin: string): Record<string, string> {
  const local = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  return {
    "Access-Control-Allow-Origin":
      ALLOWED_ORIGINS.includes(origin) || local ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const normalizeCode = (raw: unknown) =>
  typeof raw === "string" ? raw.toUpperCase().replace(/[^A-Z0-9]/g, "") : "";
const normalizeEmail = (raw: unknown) =>
  typeof raw === "string" ? raw.trim().toLowerCase() : "";

Deno.serve(async (req) => {
  const headers = {
    ...corsHeaders(req.headers.get("origin") ?? ""),
    "Content-Type": "application/json",
  };
  const reply = (status: number, body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), { status, headers });

  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });

  let body: { email?: unknown; code?: unknown; password?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Send JSON with an email, a code and a password." });
  }

  const email = normalizeEmail(body.email);
  const code = normalizeCode(body.code);
  const password = body.password;
  const badCode = {
    error: "That email and setup code don't match. Check both, or contact your instructor.",
  };

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return reply(400, { error: "Enter the email address your instructor has on file." });
  }
  if (!/^[A-Z0-9]{6,16}$/.test(code)) return reply(400, badCode);
  if (typeof password !== "string" || password.length < MIN_PASSWORD) {
    return reply(400, { error: `Choose a password of at least ${MIN_PASSWORD} characters.` });
  }
  if (password.length > MAX_PASSWORD) {
    return reply(400, { error: `Choose a password of at most ${MAX_PASSWORD} characters.` });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const { data: row, error: readError } = await admin
    .from("roster")
    .select("code, student_name, email, active, allow_reset, user_id")
    .eq("code", code)
    .maybeSingle();
  if (readError) {
    console.error("roster read failed", readError);
    return reply(500, { error: "Sign-up is unavailable right now. Try again in a minute." });
  }
  // Same answer whether the code is unknown or belongs to someone else, so the
  // form can't be used to discover which emails are on the roster.
  if (!row || !row.active || !row.email || row.email !== email) return reply(404, badCode);

  // Already set up: only allowed when the instructor has turned on a reset.
  if (row.user_id) {
    if (!row.allow_reset) {
      return reply(409, {
        error: "You've already set up your password. Sign in with your email and password, " +
          "or ask your instructor to reset it if you've forgotten it.",
      });
    }
    const { error } = await admin.auth.admin.updateUserById(row.user_id, { password });
    if (error) return reply(400, { error: "Couldn't set that password: " + error.message });
    await admin.from("roster").update({ allow_reset: false }).eq("code", code);
    return reply(200, { email, reset: true });
  }

  // Reserve the code so two requests can't both create an account. The
  // auth.users trigger in setup.sql only accepts an account for a reserved,
  // unlinked code.
  const cutoff = new Date(Date.now() - STALE_RESERVATION_MS).toISOString();
  const { data: reserved, error: reserveError } = await admin
    .from("roster")
    .update({ claimed_at: new Date().toISOString() })
    .eq("code", code)
    .is("user_id", null)
    .or(`claimed_at.is.null,claimed_at.lt."${cutoff}"`)
    .select("code");
  if (reserveError) {
    console.error("reserve failed", reserveError);
    return reply(500, { error: "Sign-up is unavailable right now. Try again in a minute." });
  }
  if (!reserved || reserved.length === 0) {
    return reply(409, { error: "This code is being set up right now. Wait a minute, then sign in." });
  }
  const release = () =>
    admin.from("roster").update({ claimed_at: null }).eq("code", code).is("user_id", null);

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true, // mark confirmed so no confirmation email is sent
    user_metadata: { student_name: row.student_name },
  });
  if (createError || !created?.user) {
    await release();
    console.error("createUser failed", createError);
    return reply(400, {
      error: "Couldn't create your account: " + (createError?.message ?? "unknown error"),
    });
  }

  const { error: linkError } = await admin
    .from("roster")
    .update({ user_id: created.user.id, claimed_at: new Date().toISOString(), allow_reset: false })
    .eq("code", code);
  if (linkError) {
    // Undo, so the student can simply try again.
    await admin.auth.admin.deleteUser(created.user.id);
    await release();
    console.error("roster link failed", linkError);
    return reply(500, { error: "Sign-up is unavailable right now. Try again in a minute." });
  }

  return reply(200, { email });
});
