import { describe, expect, it } from "vitest"
import { ADMIN_NAV, groupNavSections, type AdminNavItem } from "./nav"
import type { UserRole } from "@/lib/roles"
import { LayoutDashboard } from "lucide-react"

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

// This snapshot is the exact {key, roles} set from origin/main's nav.ts at
// the time this branch was rebuilt (44f8fc1) — every group/label/ordering
// change since then left `roles` untouched. If a future edit here changes
// who can see what, this test fails; that's the point (owner instruction
// 2026-10-29: "no role gains or loses any item compared with origin/main").
const ORIGIN_MAIN_ROLES: Record<string, UserRole[]> = {
  dashboard: ["master", "operation_admin", "sales_admin"],
  myDay: ["master", "sales_admin"],
  customers: ["master", "sales_admin"],
  sales: ["master", "sales_admin"],
  quotations: ["master", "sales_admin"],
  leads: ["master", "sales_admin"],
  service: ["master", "operation_admin"],
  amc: ["master"],
  rentals: ["master", "sales_admin"],
  technicians: ["master", "operation_admin"],
  inventory: ["master", "operation_admin"],
  suppliers: ["master", "operation_admin"],
  purchase: ["master", "operation_admin"],
  automation: ["master", "sales_admin"],
  campaigns: ["master", "sales_admin"],
  complaints: ["master", "operation_admin"],
  returns: ["master", "operation_admin"],
  hr: ["master"],
  accounts: ["master"],
  reports: ["master"],
  masters: ["master"],
  approvals: ["master"],
  auditLog: ["master"],
  tasks: ["master", "operation_admin", "sales_admin"],
  huddle: ["master", "operation_admin", "sales_admin"],
  workspace: ["master", "operation_admin", "sales_admin"],
  notifications: ["master", "operation_admin", "sales_admin"],
}

function keysVisibleTo(role: UserRole, roleMap: Record<string, UserRole[]>): Set<string> {
  return new Set(Object.entries(roleMap).filter(([, roles]) => roles.includes(role)).map(([key]) => key))
}

describe("permission parity vs origin/main (no role gains or loses an item)", () => {
  const ALL_ROLES: UserRole[] = ["master", "operation_admin", "sales_admin", "technician", "customer"]

  it("matches the origin/main key set exactly (same items, nothing added or removed)", () => {
    expect(new Set(ADMIN_NAV.map((i) => i.key))).toEqual(new Set(Object.keys(ORIGIN_MAIN_ROLES)))
  })

  for (const role of ALL_ROLES) {
    it(`${role} sees exactly the same keys as on origin/main`, () => {
      const current = keysVisibleTo(role, Object.fromEntries(ADMIN_NAV.map((i) => [i.key, i.roles])))
      const baseline = keysVisibleTo(role, ORIGIN_MAIN_ROLES)
      expect(current).toEqual(baseline)
    })
  }
})

describe("fallback 'More' group for items that ship without a group", () => {
  function fakeItem(key: string, roles: UserRole[], group?: AdminNavItem["group"]): AdminNavItem {
    return { key, labelKey: `nav.${key}`, path: `/admin/${key}`, icon: LayoutDashboard, roles, group }
  }

  it("an unmapped item shows up under 'more' for a role that has access", () => {
    const withFake = [...ADMIN_NAV, fakeItem("futureFeature", ["master"])]
    const masterItems = withFake.filter((i) => i.roles.includes("master"))
    const sections = groupNavSections(masterItems)
    const moreSection = sections.find((s) => s.section === "more")
    expect(moreSection).toBeDefined()
    expect(moreSection!.items.some((i) => i.key === "futureFeature")).toBe(true)
  })

  it("the same unmapped item is absent for a role that does not have access", () => {
    const withFake = [...ADMIN_NAV, fakeItem("futureFeature", ["master"])]
    const opsItems = withFake.filter((i) => i.roles.includes("operation_admin"))
    const sections = groupNavSections(opsItems)
    const moreSection = sections.find((s) => s.section === "more")
    // operation_admin has no ADMIN_NAV items that are themselves unmapped,
    // so if "more" shows up at all here, it must not contain the fake item
    // meant only for master.
    expect(moreSection?.items.some((i) => i.key === "futureFeature") ?? false).toBe(false)
  })

  it("'more' always renders last, after every named section", () => {
    const withFake = [...ADMIN_NAV, fakeItem("futureFeature", ["master"])]
    const sections = groupNavSections(withFake.filter((i) => i.roles.includes("master")))
    expect(sections.at(-1)?.section).toBe("more")
  })

  it("an item that already names a real group never lands in 'more'", () => {
    const withFake = [...ADMIN_NAV, fakeItem("futureFeature", ["master"], "money")]
    const sections = groupNavSections(withFake.filter((i) => i.roles.includes("master")))
    const moreSection = sections.find((s) => s.section === "more")
    expect(moreSection?.items.some((i) => i.key === "futureFeature") ?? false).toBe(false)
    const moneySection = sections.find((s) => s.section === "money")
    expect(moneySection?.items.some((i) => i.key === "futureFeature")).toBe(true)
  })
})
