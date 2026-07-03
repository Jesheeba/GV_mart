import type { Enums } from "@/types/database"

export type UserRole = Enums<"user_role">

export const STAFF_ROLES: UserRole[] = ["master", "operation_admin", "sales_admin"]

const ROLE_HOME_PATH: Record<UserRole, string> = {
  master: "/admin",
  operation_admin: "/admin",
  sales_admin: "/admin",
  technician: "/technician",
  customer: "/customer",
}

export function roleHomePath(role: UserRole) {
  return ROLE_HOME_PATH[role]
}
