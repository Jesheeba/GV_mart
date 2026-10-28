import {
  LayoutDashboard,
  CalendarCheck,
  Users,
  ShoppingCart,
  FileText,
  Target,
  Wrench,
  ShieldCheck,
  UserCog,
  Boxes,
  Truck,
  Zap,
  Wallet,
  BarChart3,
  Settings,
  ClipboardList,
  Receipt,
  Bell,
  CheckSquare,
  ListChecks,
  AlertTriangle,
  Megaphone,
  RotateCcw,
  ScrollText,
  CalendarClock,
  TrendingDown,
  Users2,
  type LucideIcon,
} from "lucide-react"
import type { UserRole } from "@/lib/roles"

export type AdminNavGroup = "salesPipeline" | "myWork" | "serviceOps" | "supplyChain" | "money" | "marketing" | "admin"

export type AdminNavItem = {
  key: string
  labelKey: string
  path: string
  icon: LucideIcon
  roles: UserRole[]
  /** exact match only (used for Dashboard so it doesn't stay "active" under every sub-route) */
  end?: boolean
  /** Sidebar section this item renders under (a small-caps divider label). Omitted for Dashboard, which is pinned above every group. */
  group?: AdminNavGroup
}

const ALL_STAFF: UserRole[] = ["master", "operation_admin", "sales_admin"]

// Role -> sidebar mapping per the Vite plan's Phase 2 prompt: master = all;
// operation_admin = Dashboard + Service (incl. scheduling) + Technicians +
// Workspace; sales_admin = Dashboard + Sales + Quotations + Leads +
// Customers (+ Workspace, per ADM-31 "Operation / Sales Admin"). Every other
// module is master-only until its own phase assigns broader access.
//
// Phase 4: inventory + suppliers move to master + operation_admin, matching
// the RLS boundary already set in Phase 1 (inventory_write_ops /
// suppliers_write_ops both allow is_ops_staff()) — masters (brands, models,
// products, spares, gifts, amc_plans, incentive_rules, settings) stay
// master-only, matching master-only RLS write policies for those tables.
// Grouped per the 2026-10-28 nav audit (GV Mart Admin — Navigation & Feature
// Audit). Pure sidebar presentation change — no roles, paths or behavior
// changed, and nothing removed: Complaints stays exactly as it was (see
// PHASE2_PROPOSALS.md for the "retire Complaints" idea, not acted on here).
// Dashboard is intentionally ungrouped (`group` omitted) so it stays pinned
// above every section.
export const ADMIN_NAV: AdminNavItem[] = [
  { key: "dashboard", labelKey: "nav.dashboard", path: "/admin", icon: LayoutDashboard, roles: ALL_STAFF, end: true },

  // Sales Pipeline: lead → quote → sale, plus the two other customer-facing
  // commitments (rentals, AMC/warranty) that follow the same cadence.
  { key: "leads", labelKey: "nav.leads", path: "/admin/leads", icon: Target, roles: ["master", "sales_admin"], group: "salesPipeline" },
  { key: "quotations", labelKey: "nav.quotations", path: "/admin/quotations", icon: FileText, roles: ["master", "sales_admin"], group: "salesPipeline" },
  { key: "sales", labelKey: "nav.sales", path: "/admin/sales", icon: ShoppingCart, roles: ["master", "sales_admin"], group: "salesPipeline" },
  { key: "rentals", labelKey: "nav.rentals", path: "/admin/rentals", icon: CalendarClock, roles: ["master", "sales_admin"], group: "salesPipeline" },
  { key: "amc", labelKey: "nav.amcWarranty", path: "/admin/amc", icon: ShieldCheck, roles: ["master"], group: "salesPipeline" },

  // My Work: the four personal/team "what's next" surfaces. Kept as separate
  // items (each has a distinct purpose — see the audit) but grouped so the
  // nav signals they're related views of a day's work, not four separate apps.
  { key: "myDay", labelKey: "nav.myDay", path: "/admin/my-day", icon: CalendarCheck, roles: ["master", "sales_admin"], group: "myWork" },
  { key: "workspace", labelKey: "nav.workspace", path: "/admin/workspace", icon: ClipboardList, roles: ALL_STAFF, group: "myWork" },
  { key: "huddle", labelKey: "nav.huddle", path: "/admin/huddle", icon: Users2, roles: ALL_STAFF, group: "myWork" },
  { key: "tasks", labelKey: "nav.tasks", path: "/admin/tasks", icon: ListChecks, roles: ALL_STAFF, group: "myWork" },

  // Service Operations. Complaints kept unchanged — see PHASE2_PROPOSALS.md.
  { key: "service", labelKey: "nav.service", path: "/admin/service", icon: Wrench, roles: ["master", "operation_admin"], group: "serviceOps" },
  { key: "technicians", labelKey: "nav.technicians", path: "/admin/technicians", icon: UserCog, roles: ["master", "operation_admin"], group: "serviceOps" },
  { key: "complaints", labelKey: "nav.complaints", path: "/admin/complaints", icon: AlertTriangle, roles: ["master", "operation_admin"], group: "serviceOps" },
  { key: "returns", labelKey: "nav.returns", path: "/admin/returns", icon: RotateCcw, roles: ["master", "operation_admin"], group: "serviceOps" },

  // Supply Chain: vendor master data -> purchase orders -> stock on hand.
  { key: "inventory", labelKey: "nav.inventory", path: "/admin/inventory", icon: Boxes, roles: ["master", "operation_admin"], group: "supplyChain" },
  { key: "suppliers", labelKey: "nav.suppliers", path: "/admin/suppliers", icon: Truck, roles: ["master", "operation_admin"], group: "supplyChain" },
  { key: "purchase", labelKey: "nav.purchase", path: "/admin/purchase", icon: Receipt, roles: ["master", "operation_admin"], group: "supplyChain" },

  // Money: Accounts now also holds the full P&L report (moved out of
  // Reports — see audit and the P&L-move commit).
  { key: "accounts", labelKey: "nav.accounts", path: "/admin/accounts", icon: TrendingDown, roles: ["master"], group: "money" },
  { key: "hr", labelKey: "nav.hr", path: "/admin/hr", icon: Wallet, roles: ["master"], group: "money" },

  // Marketing & Messaging.
  { key: "campaigns", labelKey: "nav.campaigns", path: "/admin/campaigns", icon: Megaphone, roles: ["master", "sales_admin"], group: "marketing" },
  { key: "automation", labelKey: "nav.automation", path: "/admin/automation", icon: Zap, roles: ["master", "sales_admin"], group: "marketing" },

  // Admin / Oversight.
  { key: "customers", labelKey: "nav.customers", path: "/admin/customers", icon: Users, roles: ["master", "sales_admin"], group: "admin" },
  { key: "approvals", labelKey: "nav.approvals", path: "/admin/approvals", icon: CheckSquare, roles: ["master"], group: "admin" },
  { key: "reports", labelKey: "nav.reports", path: "/admin/reports", icon: BarChart3, roles: ["master"], group: "admin" },
  { key: "masters", labelKey: "nav.masters", path: "/admin/masters", icon: Settings, roles: ["master"], group: "admin" },
  { key: "auditLog", labelKey: "nav.auditLog", path: "/admin/audit-log", icon: ScrollText, roles: ["master"], group: "admin" },
  { key: "notifications", labelKey: "nav.notifications", path: "/admin/notifications", icon: Bell, roles: ALL_STAFF, group: "admin" },
]
