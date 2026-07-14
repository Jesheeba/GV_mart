// Browser calls these functions cross-origin (the Vite dev server / deployed
// app is a different origin than the Supabase project URL), so every
// response — including the CORS preflight OPTIONS — needs these headers.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
}

export function handleCors(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders })
  }
  return null
}
