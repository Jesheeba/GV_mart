import { describe, expect, it } from "vitest"
import { ADMIN_NAV } from "./nav"
import type { UserRole } from "@/lib/roles"

// Mirrors exactly what AdminShell.tsx does to build the sidebar:
// `ADMIN_NAV.filter((item) => item.roles.includes(profile.role))`. Pure
// array-filtering logic, no rendering — consistent with this repo's
// node-environment, no-DOM vitest convention.
function sidebarItemsFor(role: UserRole) {
  return ADMIN_NAV.filter((item) => item.roles.includes(role))
}

describe("admin sidebar visibility per role", () => {
  it("master sees every nav item", () => {
    expect(sidebarItemsFor("master")).toHaveLength(ADMIN_NAV.length)
  })

  it("operation_admin sees a role-scoped subset of master's items, including Dashboard", () => {
    const opsItems = sidebarItemsFor("operation_admin")
    const masterKeys = new Set(sidebarItemsFor("master").map((i) => i.key))
    expect(opsItems.length).toBeGreaterThan(0)
    expect(opsItems.length).toBeLessThan(ADMIN_NAV.length)
    expect(opsItems.every((i) => masterKeys.has(i.key))).toBe(true)
    expect(opsItems.some((i) => i.key === "dashboard")).toBe(true)
  })

  it("sales_admin sees a role-scoped subset of master's items, including Dashboard", () => {
    const salesItems = sidebarItemsFor("sales_admin")
    const masterKeys = new Set(sidebarItemsFor("master").map((i) => i.key))
    expect(salesItems.length).toBeGreaterThan(0)
    expect(salesItems.length).toBeLessThan(ADMIN_NAV.length)
    expect(salesItems.every((i) => masterKeys.has(i.key))).toBe(true)
    expect(salesItems.some((i) => i.key === "dashboard")).toBe(true)
  })

  it("technician sees no admin sidebar items at all", () => {
    expect(sidebarItemsFor("technician")).toHaveLength(0)
  })

  it("customer sees no admin sidebar items at all", () => {
    expect(sidebarItemsFor("customer")).toHaveLength(0)
  })

  it("every grouped item names a real section label and Dashboard stays ungrouped", () => {
    const dashboard = ADMIN_NAV.find((i) => i.key === "dashboard")
    expect(dashboard?.group).toBeUndefined()
    const grouped = ADMIN_NAV.filter((i) => i.key !== "dashboard")
    expect(grouped.every((i) => !!i.group)).toBe(true)
  })

  it("Complaints is present, unchanged, and grouped under Service Operations", () => {
    const complaints = ADMIN_NAV.find((i) => i.key === "complaints")
    expect(complaints).toBeDefined()
    expect(complaints?.path).toBe("/admin/complaints")
    expect(complaints?.group).toBe("serviceOps")
  })
})
