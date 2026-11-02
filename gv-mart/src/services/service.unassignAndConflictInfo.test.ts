import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * Urgent reassign-error investigation (2026-11-02).
 *
 * 1. unassignAppointment used to be a single `appointments.technician_id =
 *    null` update with nothing else — leaving service_tickets.status stuck
 *    at 'assigned' with no technician on the appointment (found live on
 *    ticket f10206aa-9bf2-46b6-bcd0-0bf49c9c2958). It must now also revert
 *    the ticket to 'open', but ONLY when the ticket is still showing
 *    'assigned' (never in_progress / completed / cancelled), mirroring the
 *    guard assign_ticket_technician's own force-reassign branch uses
 *    server-side.
 * 2. getConflictAppointmentInfo turns a conflict_appointment_id into a human
 *    job label + the real conflicting time, for the ticket-detail "busy"
 *    message (instead of a bare, untranslated reason_key on screen).
 */

type FromCall = { table: string; calls: { method: string; args: unknown[] }[] }
const fromCalls: FromCall[] = []
let responses: Record<string, { data: unknown; error: unknown }> = {}

function makeBuilder(table: string): unknown {
  const record: FromCall = { table, calls: [] }
  fromCalls.push(record)
  const resolve = () => responses[table] ?? { data: null, error: null }
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (res: (v: unknown) => void) => res(resolve())
      }
      if (prop === "single" || prop === "maybeSingle") {
        return (...args: unknown[]) => {
          record.calls.push({ method: prop, args })
          return Promise.resolve(resolve())
        }
      }
      return (...args: unknown[]) => {
        record.calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    from: (table: string) => makeBuilder(table),
    rpc: vi.fn(),
  },
}))

import { getConflictAppointmentInfo, unassignAppointment } from "@/services/service"

beforeEach(() => {
  fromCalls.length = 0
  responses = {}
})

describe("unassignAppointment — urgent reassign-error investigation (2026-11-02)", () => {
  it("nulls the appointment's technician_id AND reverts the ticket to 'open' when it was 'assigned'", async () => {
    responses.appointments = { data: { id: "appt-1", ticket_id: "ticket-1", technician_id: null }, error: null }
    responses.service_tickets = { data: null, error: null }

    await unassignAppointment("appt-1")

    const apptCall = fromCalls.find((c) => c.table === "appointments")
    const ticketCall = fromCalls.find((c) => c.table === "service_tickets")

    expect(apptCall?.calls.some((c) => c.method === "update" && (c.args[0] as Record<string, unknown>).technician_id === null)).toBe(true)

    expect(ticketCall).toBeDefined()
    expect(ticketCall?.calls.some((c) => c.method === "update" && (c.args[0] as Record<string, unknown>).status === "open")).toBe(true)
    // Guard: only a ticket still showing 'assigned' is reopened.
    expect(ticketCall?.calls.some((c) => c.method === "eq" && c.args[0] === "status" && c.args[1] === "assigned")).toBe(true)
    expect(ticketCall?.calls.some((c) => c.method === "eq" && c.args[0] === "id" && c.args[1] === "ticket-1")).toBe(true)
  })

  it("does nothing to service_tickets when the updated appointment has no ticket_id", async () => {
    responses.appointments = { data: { id: "appt-2", ticket_id: null, technician_id: null }, error: null }

    await unassignAppointment("appt-2")

    expect(fromCalls.find((c) => c.table === "service_tickets")).toBeUndefined()
  })
})

describe("getConflictAppointmentInfo — urgent reassign-error investigation (2026-11-02)", () => {
  it("prefers the conflicting ticket's own complaint name as the job label", async () => {
    responses.appointments = {
      data: {
        id: "conflict-appt",
        scheduled_at: "2026-11-03T07:00:00+00:00",
        ends_at: "2026-11-03T07:45:00+00:00",
        ticket_id: "ticket-xyz",
        service_tickets: { name_of_complaint: "AC not cooling", products: null, unlisted_product_name: null },
      },
      error: null,
    }

    const info = await getConflictAppointmentInfo("conflict-appt")

    expect(info).toEqual({
      id: "conflict-appt",
      scheduledAt: "2026-11-03T07:00:00+00:00",
      endsAt: "2026-11-03T07:45:00+00:00",
      ticketId: "ticket-xyz",
      jobLabel: "AC not cooling",
    })
  })

  it("falls back to the catalog product name when there is no complaint name", async () => {
    responses.appointments = {
      data: {
        id: "conflict-appt-2",
        scheduled_at: null,
        ends_at: null,
        ticket_id: "ticket-abc12345",
        service_tickets: { name_of_complaint: null, products: { name: "Water Purifier" }, unlisted_product_name: null },
      },
      error: null,
    }

    const info = await getConflictAppointmentInfo("conflict-appt-2")
    expect(info?.jobLabel).toBe("Water Purifier")
  })

  it("falls back to a short ticket id when nothing else names the job", async () => {
    responses.appointments = {
      data: {
        id: "conflict-appt-3",
        scheduled_at: null,
        ends_at: null,
        ticket_id: "ticket-abc12345",
        service_tickets: { name_of_complaint: null, products: null, unlisted_product_name: null },
      },
      error: null,
    }

    const info = await getConflictAppointmentInfo("conflict-appt-3")
    expect(info?.jobLabel).toBe("Ticket ticket-a")
  })

  it("returns null when the conflicting appointment no longer exists", async () => {
    responses.appointments = { data: null, error: null }
    const info = await getConflictAppointmentInfo("missing")
    expect(info).toBeNull()
  })
})
