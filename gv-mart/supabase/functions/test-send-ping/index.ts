// TEMPORARY diagnostic function — not part of the app. Calls the real
// deployed sendMessage() directly with a plain-text (no `interactive`)
// payload, bypassing the bot's conversational flow entirely, so we can
// verify WASI_API_BASE_URL + credentials + the real outbound API call
// work independent of the interactive-format question. Delete this
// function (and this file) once the test is done.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { sendMessage } from "../_shared/whatsapp.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

const ORG_ID = "b6822905-5557-4e43-a606-f26ecfd5a541"

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  let body: { to?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400)
  }
  if (!body.to || !/^\d{10}$/.test(body.to)) {
    return jsonResponse({ error: "Body must include `to` as a bare 10-digit phone number" }, 400)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: "Missing Supabase service credentials" }, 500)

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const result = await sendMessage(admin, {
    orgId: ORG_ID,
    to: body.to,
    customerId: null,
    template: "test.ping",
    body: "Hi Jeshee, this is a test message from GV Mart. If you're reading this, the connection works! 🎉",
    type: "text",
  })

  return jsonResponse(result)
})
