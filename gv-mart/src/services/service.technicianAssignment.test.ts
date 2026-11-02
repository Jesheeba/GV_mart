import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * Urgent item 1 (2026-11-02) — "master assigns a complaint, technician ends
 * up as Karthik Raja instead of who was picked". Root cause: the New
 * Complaint form had no explicit technician field at all (only an
 * autoAssign checkbox, defaulted ON, and a "referred by technician" picker
 * that only ever feeds a referral lead row, never the appointment). This
 * pins the service-layer contract the fix depends on:
 *
 *  - createComplaintTicket forwards technicianId as p_technician_id verbatim
 *    (never substituting any other field's value, never a fallback id).
 *  - assignTicketTechnician (the existing reassign/manual-assign RPC
 *    wrapper, already correct) forwards technicianId as p_technician_id
 *    verbatim on both a fresh assign and a reassign.
 *  - No selection means p_technician_id is null, not any particular
 *    technician's id.
 *  - referredByTechnicianId and technicianId are independent knobs — a
 *    referral pick must never leak into the assignment param, and vice
 *    versa.
 */
const rpcCalls: { fn: string; args: unknown }[] = []
let rpcResult: { data: unknown; error: unknown } = { data: {}, error: null }

const updateState: { calls: { method: string; args: unknown[] }[] } = { calls: [] }
function fromBuilder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: {}, error: null })
      }
      return (...args: unknown[]) => {
        updateState.calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    rpc: (fn: string, args?: unknown) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: () => fromBuilder(),
  },
}))

import { assignTicketTechnician, createComplaintTicket, updateTicketProduct, type CreateComplaintInput } from "@/services/service"

const TECH_A = "11111111-1111-1111-1111-111111111111"
const TECH_B = "22222222-2222-2222-2222-222222222222"
const REFERRER = "33333333-3333-3333-3333-333333333333"

const baseInput: CreateComplaintInput = {
  orgId: "org-1",
  customerId: "cust-1",
  addressId: "addr-1",
  productId: "prod-1",
  brandId: null,
  modelId: null,
  nameOfComplaint: "Not cooling",
  natureOfComplaint: null,
  priority: "normal",
  channel: "call",
  appointmentMode: "always",
  autoAssign: true,
}

beforeEach(() => {
  rpcCalls.length = 0
  updateState.calls = []
  rpcResult = { data: { ticket_id: "t1", appointment_id: "a1" }, error: null }
})

function lastRpcArgs(fn: string) {
  const call = [...rpcCalls].reverse().find((c) => c.fn === fn)
  return call?.args as Record<string, unknown> | undefined
}

// Urgent outage hotfix (2026-11-02): createComplaintTicket no longer sends
// p_technician_id -- the live create_complaint_ticket RPC doesn't have that
// parameter yet (migration 20261202090000 not applied), and sending it broke
// every complaint creation in production. Skipped until the merged #4+#1
// migration is live and this forwarding is restored. See DECISIONS.md.
describe.skip("createComplaintTicket — explicit technician pick (create flow)", () => {
  it("create with technician A selected -> p_technician_id is exactly A", async () => {
    await createComplaintTicket({ ...baseInput, technicianId: TECH_A })
    expect(lastRpcArgs("create_complaint_ticket")?.p_technician_id).toBe(TECH_A)
  })

  it("no technician selected -> p_technician_id is null, never a default person", async () => {
    await createComplaintTicket({ ...baseInput })
    expect(lastRpcArgs("create_complaint_ticket")?.p_technician_id).toBeNull()
  })

  it("technicianId omitted but autoAssign true -> still sends null (auto-assign is a separate param, not a stand-in id)", async () => {
    await createComplaintTicket({ ...baseInput, autoAssign: true })
    const args = lastRpcArgs("create_complaint_ticket")
    expect(args?.p_technician_id).toBeNull()
    expect(args?.p_auto_assign).toBe(true)
  })

  it("a referral pick (referredByTechnicianId) never leaks into p_technician_id", async () => {
    await createComplaintTicket({ ...baseInput, referredByTechnicianId: REFERRER, technicianId: TECH_A })
    const args = lastRpcArgs("create_complaint_ticket")
    expect(args?.p_referred_by_technician_id).toBe(REFERRER)
    expect(args?.p_technician_id).toBe(TECH_A)
  })
})

describe("assignTicketTechnician — manual assign / reassign flow", () => {
  beforeEach(() => {
    rpcResult = { data: { assigned: true, technician_id: TECH_A }, error: null }
  })

  it("assign to technician A -> p_technician_id is exactly A", async () => {
    await assignTicketTechnician("appt-1", TECH_A)
    expect(lastRpcArgs("assign_ticket_technician")).toEqual({
      p_appointment_id: "appt-1",
      p_technician_id: TECH_A,
      p_force: false,
    })
  })

  it("reassign from A to B -> the next call's p_technician_id is exactly B, not A", async () => {
    await assignTicketTechnician("appt-1", TECH_A)
    await assignTicketTechnician("appt-1", TECH_B)
    const args = lastRpcArgs("assign_ticket_technician")
    expect(args?.p_technician_id).toBe(TECH_B)
    expect(args?.p_technician_id).not.toBe(TECH_A)
  })

  it("force-reassign still forwards the exact chosen technician id", async () => {
    await assignTicketTechnician("appt-1", TECH_B, true)
    expect(lastRpcArgs("assign_ticket_technician")).toEqual({
      p_appointment_id: "appt-1",
      p_technician_id: TECH_B,
      p_force: true,
    })
  })
})

describe("updateTicketProduct — edit flow never touches assignment", () => {
  it("editing the ticket's product does not include technician_id in the update payload (assignment stays whatever it already was)", async () => {
    await updateTicketProduct("ticket-1", { productId: "prod-2", brandId: null, modelId: null, unlistedProductName: null })
    const updateCall = updateState.calls.find((c) => c.method === "update")
    const payload = updateCall?.args[0] as Record<string, unknown>
    expect("technician_id" in payload).toBe(false)
  })
})
