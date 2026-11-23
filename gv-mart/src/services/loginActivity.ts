import { z } from "zod"
import { supabase } from "@/lib/supabase"

// HR → Login Activity. Rows come from list_login_activity() (master-only, SECURITY DEFINER) over login_sessions,
// which triggers on auth.sessions fill. See build-docs/features/login-activity.md.

export const LOGIN_ROLE_FILTERS = ["all", "staff", "technician", "customer"] as const
export type LoginRoleFilter = (typeof LOGIN_ROLE_FILTERS)[number]

export const LOGIN_ACTIVITY_PAGE_SIZE = 50
const MAX_RANGE_DAYS = 366
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/)

export const loginActivityParamsSchema = z
  .object({
    from: isoDate,
    to: isoDate,
    role: z.enum(LOGIN_ROLE_FILTERS),
    search: z.string().trim().max(100),
    page: z.number().int().min(0),
  })
  .refine((p) => p.from <= p.to, { message: "from must not be after to", path: ["to"] })
  .refine((p) => (Date.parse(p.to) - Date.parse(p.from)) / 86_400_000 <= MAX_RANGE_DAYS, {
    message: "range too long",
    path: ["from"],
  })
export type LoginActivityParams = z.infer<typeof loginActivityParamsSchema>

export type LoginActivityRow = {
  session_id: string
  user_id: string
  full_name: string | null
  phone: string | null
  role: string | null
  started_at: string
  last_seen_at: string | null
  ended_at: string | null
  user_agent: string | null
  total_count: number
}

export async function listLoginActivity(params: LoginActivityParams): Promise<{ rows: LoginActivityRow[]; total: number }> {
  const p = loginActivityParamsSchema.parse(params)
  const { data, error } = await supabase.rpc("list_login_activity" as never, {
    p_from: p.from,
    p_to: p.to,
    p_role: p.role,
    p_search: p.search || null,
    p_limit: LOGIN_ACTIVITY_PAGE_SIZE,
    p_offset: p.page * LOGIN_ACTIVITY_PAGE_SIZE,
  } as never)
  if (error) throw error
  const rows = (data ?? []) as unknown as LoginActivityRow[]
  return { rows, total: Number(rows[0]?.total_count ?? 0) }
}

/** Short device label from a user agent: "Android app", "Chrome · Windows", "Safari · iPhone". */
export function describeDevice(ua: string | null | undefined): string | null {
  if (!ua) return null
  // Capacitor Android WebView carries "; wv)"; that's our installed app, not a browser.
  if (/Android/.test(ua) && /; wv\)/.test(ua)) return "Android app"
  const os = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android"
    : /Windows/.test(ua) ? "Windows" : /Mac OS X|Macintosh/.test(ua) ? "Mac" : /Linux/.test(ua) ? "Linux" : null
  const browser = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
    : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : null
  const label = [browser, os].filter(Boolean).join(" · ")
  return label || "Other"
}

/**
 * Session length from login to logout (or to last activity while still signed in).
 * Returns null when the end is unknown or before the start (clock skew).
 */
export function sessionDurationMinutes(row: Pick<LoginActivityRow, "started_at" | "ended_at" | "last_seen_at">): number | null {
  const end = row.ended_at ?? row.last_seen_at
  if (!end) return null
  const ms = Date.parse(end) - Date.parse(row.started_at)
  if (!Number.isFinite(ms) || ms < 0) return null
  return Math.floor(ms / 60_000)
}

/** "3d 4h", "2h 05m", "12m", "<1m". */
export function formatDuration(minutes: number | null): string {
  if (minutes === null) return "—"
  if (minutes < 1) return "<1m"
  const d = Math.floor(minutes / 1440)
  const h = Math.floor((minutes % 1440) / 60)
  const m = minutes % 60
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`
  return `${m}m`
}
