// Technician shift-end prompt, midnight safety net (20260831140000). If a
// technician left a shift-end popup unanswered (closed the app, lost
// signal, etc.), their attendance row's shift_end_prompt_pending stays true
// forever otherwise — this force-closes only those rows once the IST day
// they belong to has actually ended, so the next check-in starts a clean
// day. Deliberately narrow: a technician who simply forgot to check out on
// an ordinary day (no popup involved) is untouched, per design.
//
// All the actual logic lives in reset_stale_shift_end_prompts() (one UPDATE
// across every org) — this function is just the scheduling shell, same
// GitHub-Actions-cron-over-HTTP pattern as wa-scheduled-tasks/wa-milestone-
// dispatch (see those functions' own headers for why: this stack has
// deliberately avoided pg_cron elsewhere). verify_jwt is off (supabase/
// config.toml) since GitHub Actions has no Supabase session; authenticity
// is the same CRON_SECRET bearer check as its siblings.
import { createClient } from "jsr:@supabase/supabase-js@2"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const cronSecret = Deno.env.get("CRON_SECRET")
  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!cronSecret || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Not configured (missing CRON_SECRET or Supabase service credentials)" }, 500)
  }

  const authHeader = req.headers.get("Authorization")
  if (authHeader !== `Bearer ${cronSecret}`) return jsonResponse({ error: "Unauthorized" }, 401)

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const { data: resetCount, error } = await admin.rpc("reset_stale_shift_end_prompts")
  if (error) {
    console.error("technician-shift-reset: reset_stale_shift_end_prompts failed", error)
    return jsonResponse({ error: error.message }, 500)
  }

  return jsonResponse({ ranAt: new Date().toISOString(), resetCount })
})
