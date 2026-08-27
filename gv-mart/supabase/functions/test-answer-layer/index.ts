// TEMPORARY diagnostic function — not part of the app. Calls
// answerCustomerQuestion() directly with a phone + free-text question,
// bypassing the WhatsApp webhook/conversation flow entirely, so the
// orchestration logic (tool selection, RPC execution, final-answer
// generation, audit logging) can be run against a real test set before it
// ever touches live customer traffic — same "build it, test it directly,
// wire it in later" pattern as test-send-ping. Does NOT send a WhatsApp
// message; returns the full diagnostic result as JSON so each test case
// can be inspected directly. Delete this function (and this file) once the
// orchestration function is wired into handleMessage and no longer needs
// standalone testing.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { answerCustomerQuestion } from "../_shared/whatsapp-answer-layer.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

const ORG_ID = "b6822905-5557-4e43-a606-f26ecfd5a541"

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  let body: { phone?: string; question?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400)
  }
  if (!body.phone || typeof body.phone !== "string") {
    return jsonResponse({ error: "Body must include `phone`" }, 400)
  }
  if (!body.question || typeof body.question !== "string") {
    return jsonResponse({ error: "Body must include `question`" }, 400)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: "Missing Supabase service credentials" }, 500)

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const result = await answerCustomerQuestion(admin, ORG_ID, body.phone, body.question)

  return jsonResponse(result)
})
