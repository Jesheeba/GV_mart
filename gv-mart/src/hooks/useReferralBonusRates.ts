import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as referralBonusRates from "@/services/referralBonusRates"

export function useReferralBonusRates(orgId: string | undefined) {
  return useQuery({
    queryKey: ["referral_bonus_rates", "list", orgId],
    queryFn: () => referralBonusRates.listReferralBonusRates(orgId!),
    enabled: !!orgId,
  })
}

export function useSetReferralBonusRate() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: referralBonusRates.SetReferralBonusRateInput) => referralBonusRates.setReferralBonusRate(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["referral_bonus_rates"] }),
  })
}
