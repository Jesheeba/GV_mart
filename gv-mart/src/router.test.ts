import { describe, expect, it } from "vitest"
// Raw text import (Vite's `?raw`, typed by vite/client) instead of actually
// importing router.tsx: `export const router = createBrowserRouter([...])`
// runs at module load and createBrowserRouter touches `document`, which
// doesn't exist in this repo's node-environment vitest setup — and `src`
// isn't typed for Node builtins (no "node" in tsconfig.app.json's `types`),
// so `node:fs` isn't an option here either. This checks the route table as
// text instead — a regression guard on the route *shape*, not a renderer.
import routerSource from "./router.tsx?raw"

describe("admin route table (static contract check)", () => {
  it("still routes /admin/complaints to ComplaintsPage — not removed, not redirected", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"complaints",\s*element:\s*<ComplaintsPage\s*\/>\s*\}/)
  })

  it("still routes /admin/accounts to AccountsPage (now also home to the P&L tab)", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"accounts",\s*element:\s*<AccountsPage\s*\/>\s*\}/)
  })

  it("still routes /admin/reports to ReportsPage", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"reports",\s*element:\s*<ReportsPage\s*\/>\s*\}/)
  })

  it("still routes /admin/hr to HrPage (now home to the merged Salary toggle)", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"hr",\s*element:\s*<HrPage\s*\/>\s*\}/)
  })

  // P&L was always a Tabs value inside /admin/reports, never its own URL —
  // there is no "old P&L route" to redirect.

  it("still routes /admin/expenses to ExpensesPage (Monthly Expenses, landed in the 2026-10-28 release)", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"expenses",\s*element:\s*<ExpensesPage\s*\/>\s*\}/)
  })

  it("still routes /admin/leave-requests to LeaveRequestsPage (technician leave, landed in the 2026-10-28 release)", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"leave-requests",\s*element:\s*<LeaveRequestsPage\s*\/>\s*\}/)
  })

  // Workspace was retired by the release itself (folded into Tasks' My Day
  // tab) — the old URL must still resolve, as a redirect, not a 404.
  it("redirects the old /admin/workspace URL instead of dropping it", () => {
    expect(routerSource).toMatch(/\{\s*path:\s*"workspace",\s*element:\s*<Navigate\s+to="\/admin\/tasks\?view=myDay"\s+replace\s*\/>\s*\}/)
  })
})

describe("technician route table (static contract check)", () => {
  // QA smoke test bug #2 (2026-10-29): TechnicianHomePage grew a "Pending
  // Reviews" tile linking to this same route. "Renders for technician, never
  // for other roles" is a routing-level guarantee in this app (RequireRole
  // gates the whole /technician subtree, not a per-component check) -- see
  // router.test.ts's own header comment on why this file checks the route
  // table as text rather than rendering components. These two checks are
  // the route-table half of that guarantee: TechnicianHomePage and
  // PendingReviewsPage both live only inside the "/technician" block whose
  // element is <RequireRole roles={["technician"]} />, so neither is
  // reachable under any other role's route tree at all.
  function technicianBlock(): string {
    const start = routerSource.indexOf('path: "/technician"')
    expect(start).toBeGreaterThan(-1)
    const nextTopLevelRoute = routerSource.indexOf('path: "/', start + 1)
    return routerSource.slice(start, nextTopLevelRoute > -1 ? nextTopLevelRoute : undefined)
  }

  it('the "/technician" route is gated by RequireRole roles={["technician"]} -- not any broader role list', () => {
    const block = technicianBlock()
    const guardIndex = block.indexOf("RequireRole")
    expect(guardIndex).toBeGreaterThan(-1)
    expect(block.slice(guardIndex, guardIndex + 60)).toMatch(/RequireRole\s+roles=\{\["technician"\]\}/)
  })

  it("TechnicianHomePage (index route) and PendingReviewsPage both live inside that technician-only block", () => {
    const block = technicianBlock()
    expect(block).toMatch(/\{\s*index:\s*true,\s*element:\s*<TechnicianHomePage\s*\/>\s*\}/)
    expect(block).toMatch(/\{\s*path:\s*"pending-reviews",\s*element:\s*<PendingReviewsPage\s*\/>\s*\}/)
  })

  it("TechnicianHomePage and PendingReviewsPage appear nowhere outside the technician block (e.g. not also mounted under /admin)", () => {
    const block = technicianBlock()
    const outsideBlock = routerSource.slice(0, routerSource.indexOf('path: "/technician"')) + routerSource.slice(routerSource.indexOf('path: "/technician"') + block.length)
    expect(outsideBlock).not.toContain("<TechnicianHomePage")
    expect(outsideBlock).not.toContain("<PendingReviewsPage")
  })
})
