import {
  LayoutDashboard,
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
  AlertTriangle,
  Megaphone,
  RotateCcw,
  ScrollText,
  type LucideIcon,
} from "lucide-react"
import type { UserRole } from "@/lib/roles"

export type AdminNavItem = {
  key: string
  labelKey: string
  path: string
  icon: LucideIcon
  roles: UserRole[]
  /** exact match only (used for Dashboard so it doesn't stay "active" under every sub-route) */
  end?: boolean
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
export const ADMIN_NAV: AdminNavItem[] = [
  { key: "dashboard", labelKey: "nav.dashboard", path: "/admin", icon: LayoutDashboard, roles: ALL_STAFF, end: true },
  { key: "customers", labelKey: "nav.customers", path: "/admin/customers", icon: Users, roles: ["master", "sales_admin"] },
  { key: "sales", labelKey: "nav.sales", path: "/admin/sales", icon: ShoppingCart, roles: ["master", "sales_admin"] },
  { key: "quotations", labelKey: "nav.quotations", path: "/admin/quotations", icon: FileText, roles: ["master", "sales_admin"] },
  { key: "leads", labelKey: "nav.leads", path: "/admin/leads", icon: Target, roles: ["master", "sales_admin"] },
  { key: "service", labelKey: "nav.service", path: "/admin/service", icon: Wrench, roles: ["master", "operation_admin"] },
  { key: "amc", labelKey: "nav.amcWarranty", path: "/admin/amc", icon: ShieldCheck, roles: ["master"] },
  { key: "technicians", labelKey: "nav.technicians", path: "/admin/technicians", icon: UserCog, roles: ["master", "operation_admin"] },
  { key: "inventory", labelKey: "nav.inventory", path: "/admin/inventory", icon: Boxes, roles: ["master", "operation_admin"] },
  { key: "suppliers", labelKey: "nav.suppliers", path: "/admin/suppliers", icon: Truck, roles: ["master", "operation_admin"] },
  { key: "purchase", labelKey: "nav.purchase", path: "/admin/purchase", icon: Receipt, roles: ["master", "operation_admin"] },
  { key: "automation", labelKey: "nav.automation", path: "/admin/automation", icon: Zap, roles: ["master", "sales_admin"] },
  { key: "campaigns", labelKey: "nav.campaigns", path: "/admin/campaigns", icon: Megaphone, roles: ["master", "sales_admin"] },
  { key: "complaints", labelKey: "nav.complaints", path: "/admin/complaints", icon: AlertTriangle, roles: ["master", "operation_admin"] },
  { key: "returns", labelKey: "nav.returns", path: "/admin/returns", icon: RotateCcw, roles: ["master", "operation_admin"] },
  { key: "hr", labelKey: "nav.hr", path: "/admin/hr", icon: Wallet, roles: ["master"] },
  { key: "reports", labelKey: "nav.reports", path: "/admin/reports", icon: BarChart3, roles: ["master"] },
  { key: "masters", labelKey: "nav.masters", path: "/admin/masters", icon: Settings, roles: ["master"] },
  { key: "approvals", labelKey: "nav.approvals", path: "/admin/approvals", icon: CheckSquare, roles: ["master"] },
  { key: "auditLog", labelKey: "nav.auditLog", path: "/admin/audit-log", icon: ScrollText, roles: ["master"] },
  { key: "workspace", labelKey: "nav.workspace", path: "/admin/workspace", icon: ClipboardList, roles: ALL_STAFF },
  { key: "notifications", labelKey: "nav.notifications", path: "/admin/notifications", icon: Bell, roles: ALL_STAFF },
]
