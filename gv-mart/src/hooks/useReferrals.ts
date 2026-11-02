import { useQuery } from "@tanstack/react-query"
import * as referrals from "@/services/referrals"

// Referral incentives — merged hooks file (owner-requested merge of 3 parallel UI streams'
// identically-named src/hooks/useReferrals.ts: ui-forms [useActiveReferrers], masters-report
// [useReferralBonusReport], tech-app [useReferralBonusPreview]). Kept byte-identical across all
// 3 branches on purpose so a git merge between them sees no conflict on this file.

/** customer/lead form "Referred by" picker (ui-forms stream). */
export function useActiveReferrers(orgId: string | undefined) {
  return useQuery({
    queryKey: ["referrals", "activeReferrers", orgId],
    queryFn: () => referrals.listActiveReferrers(orgId!),
    enabled: !!orgId,
  })
}

/** `period` is a calendar-month date string ("2026-11-01"); `technicianId`
 *  omitted → org-wide report (master view). HR/Masters report + rate card screens
 *  (masters-report stream). */
export function useReferralBonusReport(period: string, technicianId?: string | null) {
  return useQuery({
    queryKey: ["referral_bonus_report", period, technicianId ?? null],
    queryFn: () => referrals.getReferralBonusReport(period, technicianId ?? null),
    enabled: !!period,
  })
}

/** Technician's own Profile page "Referral bonus this month" section (tech-app stream).
 *  Always scoped server-side to the caller and the current open IST month. */
export function useReferralBonusPreview(orgId: string | undefined) {
  return useQuery({
    queryKey: ["referral_bonus_preview", orgId],
    queryFn: () => referrals.getReferralBonusPreview(orgId!),
    enabled: !!orgId,
  })
}
