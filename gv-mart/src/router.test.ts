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
