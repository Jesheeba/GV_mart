import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as automation from "@/services/automation"
import type { LeadFilters, LeadStatus, PoItemInput } from "@/services/automation"

// ── Leads ─────────────────────────────────────────────────────────────────
export function useLeads(orgId: string | undefined, filters: LeadFilters = {}) {
  return useQuery({
    queryKey: ["leads", "list", orgId, filters],
    queryFn: () => automation.listLeads(orgId!, filters),
    enabled: !!orgId,
  })
}
export function useCreateLead() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: automation.createLead,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["leads"] }),
  })
}
export function useLeadActivities(leadId: string | undefined) {
  return useQuery({
    queryKey: ["leads", "activities", leadId],
    queryFn: () => automation.listLeadActivities(leadId!),
    enabled: !!leadId,
  })
}
export function useLogLeadActivity() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ leadId, type, note }: { leadId: string; type: string; note: string | null }) => automation.logLeadActivity(leadId, type, note),
    onSuccess: (_d, vars) => qc.invalidateQueries({ queryKey: ["leads", "activities", vars.leadId] }),
  })
}
export function useUpdateLeadStatus() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ leadId, status }: { leadId: string; status: LeadStatus }) => automation.updateLeadStatus(leadId, status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["leads"] }),
  })
}
export function useAwardReferralPoints() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: automation.awardReferralPoints,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["leads"] }),
  })
}

// ── Automation flows / video library ─────────────────────────────────────
export function useAutomationFlows(orgId: string | undefined) {
  return useQuery({ queryKey: ["automationFlows", orgId], queryFn: () => automation.listAutomationFlows(orgId!), enabled: !!orgId })
}
export function useCreateAutomationFlow() {
  const qc = useQueryClient()
  return useMutation({ mutationFn: automation.createAutomationFlow, onSuccess: () => qc.invalidateQueries({ queryKey: ["automationFlows"] }) })
}
export function useUpdateAutomationFlow() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof automation.updateAutomationFlow>[1] }) => automation.updateAutomationFlow(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["automationFlows"] }),
  })
}
export function useDeleteAutomationFlow() {
  const qc = useQueryClient()
  return useMutation({ mutationFn: automation.deleteAutomationFlow, onSuccess: () => qc.invalidateQueries({ queryKey: ["automationFlows"] }) })
}

export function useVideoLibrary(orgId: string | undefined) {
  return useQuery({ queryKey: ["videoLibrary", orgId], queryFn: () => automation.listVideoLibrary(orgId!), enabled: !!orgId })
}
export function useCreateVideoLibraryEntry() {
  const qc = useQueryClient()
  return useMutation({ mutationFn: automation.createVideoLibraryEntry, onSuccess: () => qc.invalidateQueries({ queryKey: ["videoLibrary"] }) })
}
export function useUpdateVideoLibraryEntry() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof automation.updateVideoLibraryEntry>[1] }) => automation.updateVideoLibraryEntry(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["videoLibrary"] }),
  })
}
export function useDeleteVideoLibraryEntry() {
  const qc = useQueryClient()
  return useMutation({ mutationFn: automation.deleteVideoLibraryEntry, onSuccess: () => qc.invalidateQueries({ queryKey: ["videoLibrary"] }) })
}

export function useWhatsappOutbox(orgId: string | undefined) {
  return useQuery({ queryKey: ["whatsappOutbox", orgId], queryFn: () => automation.listWhatsappOutbox(orgId!), enabled: !!orgId })
}
export function useSimulateInboundWhatsapp() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: automation.simulateInboundWhatsapp,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["whatsappOutbox"] }),
  })
}

// ── Purchase ──────────────────────────────────────────────────────────────
export function usePurchaseOrders(orgId: string | undefined) {
  return useQuery({ queryKey: ["purchaseOrders", orgId], queryFn: () => automation.listPurchaseOrders(orgId!), enabled: !!orgId })
}
export function usePoItems(poId: string | undefined) {
  return useQuery({ queryKey: ["poItems", poId], queryFn: () => automation.listPoItems(poId!), enabled: !!poId })
}
export function useCreatePurchaseOrder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { orgId: string; supplierId: string; items: PoItemInput[] }) => automation.createPurchaseOrder(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["purchaseOrders"] }),
  })
}
export function usePurchaseBills(orgId: string | undefined) {
  return useQuery({ queryKey: ["purchaseBills", orgId], queryFn: () => automation.listPurchaseBills(orgId!), enabled: !!orgId })
}
export function useCreateBillEntry() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: automation.createBillEntry,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["purchaseBills"] })
      qc.invalidateQueries({ queryKey: ["purchaseOrders"] })
      qc.invalidateQueries({ queryKey: ["inventory"] })
    },
  })
}
/** Deliberately its own query key (not nested under "purchaseBills") so
 * `useCreateBillEntry`'s invalidation doesn't refetch it — Bill Entry only
 * needs this once, to prefill the form on first open; the form itself
 * resets to blank after a successful submit rather than re-prefilling. */
export function useLastBillEntry(orgId: string | undefined) {
  return useQuery({
    queryKey: ["lastBillEntry", orgId],
    queryFn: () => automation.getLastBillEntry(orgId!),
    enabled: !!orgId,
  })
}
