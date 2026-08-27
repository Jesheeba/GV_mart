// Phase 5a — free-text intent classification, standalone HTTP entry point.
// The actual classification logic lives in _shared/whatsapp-classify-intent.ts
// (Phase 5b onward: handleMessage calls that module directly, in-process).
// This wrapper stays so the classifier remains independently testable via a
// direct function call, same pattern used for the test-send-ping diagnostic.
import { corsHeaders, handleCors } from "../_shared/cors.ts"
import { classifyWithClaude } from "../_shared/whatsapp-classify-intent.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } })
}

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY")
  if (!apiKey) return jsonResponse({ error: "Not configured (missing ANTHROPIC_API_KEY)" }, 500)

  let body: { text?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400)
  }
  if (typeof body.text !== "string" || !body.text.trim()) {
    return jsonResponse({ error: "text is required" }, 400)
  }

  const result = await classifyWithClaude(body.text, apiKey)
  return jsonResponse(result)
})
