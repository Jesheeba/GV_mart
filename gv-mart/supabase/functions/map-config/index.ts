// Hands the browser the Google Maps API key at runtime instead of baking it
// into the client bundle. Unlike the old MapTiler style-URL approach, the
// Google Maps JavaScript API has no server-side proxy option — it must be
// loaded as a <script> tag directly in the browser, so this key necessarily
// becomes visible in that request once loaded. Fetching it here still keeps
// it out of source control and the static JS bundle, and lets it be rotated
// without a frontend redeploy — but the real security boundary for this key
// is an HTTP-referrer restriction in Google Cloud Console (see
// supabase/functions/.env.example), not secrecy.
import { corsHeaders, handleCors } from "../_shared/cors.ts"

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight

  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  const apiKey = Deno.env.get("GOOGLE_MAPS_API_KEY")
  if (!apiKey) {
    return new Response(JSON.stringify({ error: "Maps are not configured (missing GOOGLE_MAPS_API_KEY)" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  return new Response(JSON.stringify({ apiKey }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "private, max-age=300" },
  })
})
