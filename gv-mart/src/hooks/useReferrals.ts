import { useQuery } from "@tanstack/react-query"
import * as referrals from "@/services/referrals"

// NOTE: filename chosen fresh for this stream — no existing src/hooks/useReferrals.ts
// was found in this worktree at build time. If a parallel UI-forms stream also
// created a file by this name with a different hook in it, the two need to be
// merged by hand before merge to main (flagged in the hand-off report).

/** `period` is a calendar-month date string ("2026-11-01"); `technicianId`
 *  omitted → org-wide report (master view). Backed by the not-yet-built
 *  `referral_bonus_report` RPC — see src/services/referrals.ts header. */
export function useReferralBonusReport(period: string, technicianId?: string | null) {
  return useQuery({
    queryKey: ["referral_bonus_report", period, technicianId ?? null],
    queryFn: () => referrals.getReferralBonusReport(period, technicianId ?? null),
    enabled: !!period,
  })
}
