import { describe, expect, it } from "vitest"

/**
 * CI guard for the WhatsApp dispatcher (docs/plan-dispatcher-fix.md).
 *
 * 'sent' on a whatsapp_outbox row means "Wasi accepted it and returned a WhatsApp message id". A row may only become 'sent'
 * through the send path (wa-send-core.ts patchForOutcome, after a 201 with meta_message_id). A migration that INSERTs a row
 * with status 'sent' is an optimistic write, exactly the bug this dispatcher fix removes: nothing was sent yet.
 *
 * Twelve existing migrations already do that. They are listed below as the frozen baseline: their rows are normalised to
 * 'pending' by the trigger in 20261016310000 when settings.wa_dispatch_v2_enabled is on. A NEW migration that inserts
 * status 'sent' into whatsapp_outbox fails this test: insert 'pending' instead (the dispatcher claims and sends it).
 */
const migrations = import.meta.glob("../../supabase/migrations/*.sql", { query: "?raw", import: "default", eager: true }) as Record<string, string>
const edgeSources = import.meta.glob(["../../supabase/functions/**/*.ts", "!../../supabase/functions/**/*.test.ts"], { query: "?raw", import: "default", eager: true }) as Record<string, string>

/** Frozen on 2026-10-16. Do not add to this list; fix the new migration instead. */
const BASELINE_MIGRATIONS_WRITING_SENT = new Set([
  "20260702170100_automation_purchase_functions.sql",
  "20260702170300_automation_purchase_functions_fix.sql",
  "20260715300000_operational_alerts.sql",
  "20260722110000_reorder_formula_and_po_approval_toggle.sql",
  "20260725120000_po_quotation_first_with_timeout_safeguard.sql",
  "20260729100000_reorder_max_stock_only.sql",
  "20260819170000_whatsapp_templates_and_kill_switch.sql",
  "20260825150000_supplier_rfq_wa_automation.sql",
  "20260901110000_supplier_monthly_rfq_phase2.sql",
  "20260901120000_supplier_monthly_rfq_phase3.sql",
  "20260922100000_supplier_credit_terms_and_po_payment_reminder_tasks.sql",
  "20261015100000_whatsapp_outbound_gate.sql", // send_staff_whatsapp: staff-queued row, purchase_order refs are never dispatched
])

/** Edge Function sources allowed to write status "sent" next to whatsapp_outbox: the legacy (flag OFF) send path and the
 * legacy retry pass that closes out the original row. The v2 path never writes 'sent' except from the response handler. */
const EDGE_SOURCES_WRITING_SENT = ["/wa-scheduled-tasks/index.ts", "/_shared/whatsapp.ts"]

function baseName(path: string): string {
  return path.split("/").pop() as string
}

function insertsSentIntoOutbox(sql: string): boolean {
  const text = sql.replace(/\r\n/g, "\n")
  const re = /insert\s+into\s+(?:public\.)?whatsapp_outbox\b[\s\S]*?;/gi
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    if (/'sent'/.test(m[0])) return true
  }
  return false
}

describe("whatsapp_outbox: 'sent' is only written by the send path", () => {
  it("scans a plausible number of migrations", () => {
    expect(Object.keys(migrations).length).toBeGreaterThan(100)
  })

  it("no migration outside the frozen baseline inserts status 'sent' into whatsapp_outbox", () => {
    const offenders = Object.entries(migrations)
      .filter(([, sql]) => insertsSentIntoOutbox(sql))
      .map(([path]) => baseName(path))
      .filter((name) => !BASELINE_MIGRATIONS_WRITING_SENT.has(name))
    expect(offenders, "insert status 'pending' instead; only a confirmed send (201 + meta_message_id) makes a row 'sent'").toEqual([])
  })

  it("the baseline list is accurate (a file that stopped writing 'sent' is removed from it)", () => {
    const stale = [...BASELINE_MIGRATIONS_WRITING_SENT].filter((name) => {
      const entry = Object.entries(migrations).find(([path]) => baseName(path) === name)
      return !entry || !insertsSentIntoOutbox(entry[1])
    })
    expect(stale).toEqual([])
  })

  it("the pending-normalisation trigger migration exists, so the baseline writers are neutralised when the flag is on", () => {
    const hit = Object.entries(migrations).find(([path]) => baseName(path) === "20261016310000_wa_dispatch_v2_pending_normalisation.sql")
    expect(hit, "20261016310000_wa_dispatch_v2_pending_normalisation.sql must exist").toBeTruthy()
    expect(hit![1]).toMatch(/wa_outbox_pending_normalise/)
  })

  it("Edge Function code writes status \"sent\" next to whatsapp_outbox only in the two legacy files", () => {
    const offenders = Object.entries(edgeSources)
      .filter(([, src]) => /whatsapp_outbox/.test(src) && /(?<![A-Za-z_])status:\s*"sent"/.test(src))
      .map(([path]) => path.replace(/^.*supabase\/functions/, ""))
      .filter((p) => !EDGE_SOURCES_WRITING_SENT.includes(p))
    expect(offenders, "route the write through sendMessage / wa-send-core instead").toEqual([])
  })

  it("the v2 send core only produces 'sent' from a 201 with a meta_message_id", () => {
    const core = Object.entries(edgeSources).find(([path]) => path.endsWith("/_shared/wa-send-core.ts"))
    expect(core).toBeTruthy()
    const src = core![1]
    const sentPatches = src.match(/(?<![A-Za-z_])status:\s*"sent"/g) ?? []
    expect(sentPatches).toHaveLength(1)
    expect(src).toMatch(/if \(metaId\) return \{ kind: "sent"/)
  })
})
