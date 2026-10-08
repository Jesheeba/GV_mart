// CORS for the staff-login Edge Functions only (admin-create-staff, admin-reset-staff-password).
//
// The shared cors.ts answers "*" for every function. These two accept a bearer token that can mint or take over
// office logins, so they answer ONLY the app's own origin(s), read from the ALLOWED_ORIGINS function secret
// (comma separated, exact match, e.g. "https://gv-mart.vercel.app,capacitor://localhost,http://localhost").
// Nothing is hardcoded. If the secret is unset, no Access-Control-Allow-Origin header is sent at all, so browsers
// refuse the call: it fails closed. Set the secret BEFORE deploying these functions:
//   supabase secrets set ALLOWED_ORIGINS="https://<app domain>,capacitor://localhost" --project-ref <ref>
// (Server-to-server callers send no Origin header and are not affected by CORS.)

function allowedOrigins(): string[] {
  const raw = Deno.env.get("ALLOWED_ORIGINS") ?? ""
  return raw
    .split(",")
    .map((o) => o.trim())
    .filter((o) => o.length > 0 && o !== "*")
}

export function staffCorsHeaders(req: Request): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  }
  const origin = req.headers.get("Origin")
  if (origin && allowedOrigins().includes(origin)) headers["Access-Control-Allow-Origin"] = origin
  return headers
}

export function staffPreflight(req: Request): Response | null {
  if (req.method !== "OPTIONS") return null
  return new Response(null, { status: 204, headers: staffCorsHeaders(req) })
}
