import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as sys from "@/services/systemPages"
import type {
  AuditLogFilters,
  CreateCampaignInput,
  CreateReturnInput,
  CampaignStatus,
  ReturnStatus,
} from "@/services/systemPages"
import type { Enums } from "@/types/database"

// ── Notifications Center ─────────────────────────────────────────────────
export function useAllMyNotifications(
  orgId: string | undefined,
  userId: string | undefined,
  role: Enums<"user_role"> | undefined,
  filters: { type?: string; readStatus?: "read" | "unread" }
) {
  return useQuery({
    queryKey: ["notifications", "all", orgId, userId, role, filters],
    queryFn: () => sys.listAllMyNotifications(orgId!, userId!, role!, filters),
    enabled: !!orgId && !!userId && !!role,
  })
}

export function useMyNotificationTypes(orgId: string | undefined, userId: string | undefined, role: Enums<"user_role"> | undefined) {
  return useQuery({
    queryKey: ["notifications", "types", orgId, userId, role],
    queryFn: () => sys.listMyNotificationTypes(orgId!, userId!, role!),
    enabled: !!orgId && !!userId && !!role,
    staleTime: 60_000,
  })
}

/** Polls every 30s so the header bell badge reflects new notifications without a manual page visit/refresh. */
export function useUnreadNotificationCount(orgId: string | undefined, userId: string | undefined, role: Enums<"user_role"> | undefined) {
  return useQuery({
    queryKey: ["notifications", "unreadCount", orgId, userId, role],
    queryFn: () => sys.countUnreadNotifications(orgId!, userId!, role!),
    enabled: !!orgId && !!userId && !!role,
    refetchInterval: 30_000,
  })
}

export function useMarkNotificationRead() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, isRead }: { id: string; isRead?: boolean }) => sys.markNotificationRead(id, isRead),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["notifications"] }),
  })
}

export function useMarkAllNotificationsRead() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (ids: string[]) => sys.markAllNotificationsRead(ids),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["notifications"] }),
  })
}

// ── Approvals Queue ───────────────────────────────────────────────────────
export function useApprovals(orgId: string | undefined, filters: { type?: string; status?: string }) {
  return useQuery({
    queryKey: ["approvals", "list", orgId, filters],
    queryFn: () => sys.listApprovals(orgId!, filters),
    enabled: !!orgId,
  })
}

export function useResolveApprovalRef(type: Enums<"approval_type">, refId: string | undefined) {
  return useQuery({
    queryKey: ["approvals", "ref", type, refId],
    queryFn: () => sys.resolveApprovalRef(type, refId!),
    enabled: !!refId,
  })
}

export function useDecideApproval() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, approverId, status }: { id: string; approverId: string; status: "approved" | "rejected" }) =>
      sys.decideApproval(id, approverId, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["approvals"] }),
  })
}

/** Build Order C2: approving a `type = 'po'` approval — releases the linked draft PO, not just a status flip. */
export function useApprovePurchaseOrder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (approvalId: string) => sys.approvePurchaseOrder(approvalId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["approvals"] })
      qc.invalidateQueries({ queryKey: ["purchaseOrders"] })
    },
  })
}

// ── Complaints & Escalations ──────────────────────────────────────────────
export function useOverdueSlaTickets(orgId: string | undefined) {
  return useQuery({
    queryKey: ["complaints", "overdue", orgId],
    queryFn: () => sys.listOverdueSlaTickets(orgId!),
    enabled: !!orgId,
  })
}

export function useRepeatComplaintTickets(orgId: string | undefined) {
  return useQuery({
    queryKey: ["complaints", "repeat", orgId],
    queryFn: () => sys.listRepeatComplaintTickets(orgId!),
    enabled: !!orgId,
  })
}

// ── Campaign Manager ───────────────────────────────────────────────────────
export function useCampaigns(orgId: string | undefined) {
  return useQuery({
    queryKey: ["campaigns", "list", orgId],
    queryFn: () => sys.listCampaigns(orgId!),
    enabled: !!orgId,
  })
}

export function useCreateCampaign() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateCampaignInput) => sys.createCampaign(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["campaigns"] }),
  })
}

export function useUpdateCampaignStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: CampaignStatus }) => sys.updateCampaignStatus(id, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["campaigns"] }),
  })
}

export function useDeleteCampaign() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => sys.deleteCampaign(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["campaigns"] }),
  })
}

// ── Returns / Replacement ───────────────────────────────────────────────────
export function useReturns(orgId: string | undefined) {
  return useQuery({
    queryKey: ["returns", "list", orgId],
    queryFn: () => sys.listReturns(orgId!),
    enabled: !!orgId,
  })
}

export function useInvoicesForPicker(orgId: string | undefined) {
  return useQuery({
    queryKey: ["invoices", "picker", orgId],
    queryFn: () => sys.listInvoicesForPicker(orgId!),
    enabled: !!orgId,
  })
}

export function useCreateReturn() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateReturnInput) => sys.createReturn(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["returns"] }),
  })
}

export function useUpdateReturnStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: ReturnStatus }) => sys.updateReturnStatus(id, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["returns"] }),
  })
}

// ── Audit Log viewer ───────────────────────────────────────────────────────
export function useAuditLog(orgId: string | undefined, filters: AuditLogFilters) {
  return useQuery({
    queryKey: ["auditLog", "list", orgId, filters],
    queryFn: () => sys.listAuditLog(orgId!, filters),
    enabled: !!orgId,
  })
}

export function useAuditLogTableNames(orgId: string | undefined) {
  return useQuery({
    queryKey: ["auditLog", "tableNames", orgId],
    queryFn: () => sys.listAuditLogTableNames(orgId!),
    enabled: !!orgId,
    staleTime: 60_000,
  })
}
