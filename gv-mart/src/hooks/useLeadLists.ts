import { useTranslation } from "react-i18next"
import { useProfile } from "@/hooks/useProfile"
import { leadKindsHooks, leadProductTypesHooks } from "@/hooks/useMasters"
import { leadKindLabel, leadProductTypeLabel } from "@/lib/lead-lists"

/** Org lead kinds (Service/Spare/Product/AMC/Warranty/…) plus a label resolver for built-in and custom keys. */
export function useLeadKindOptions() {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const { data: kinds } = leadKindsHooks.useList(profile?.org_id)
  return {
    kinds: kinds ?? [],
    /** Active only — what a dropdown for a NEW lead or a filter should offer. */
    activeKinds: (kinds ?? []).filter((k) => k.is_active),
    label: (key: string) => leadKindLabel(key, kinds, t, i18n.language),
  }
}

/** Org lead product types plus a label resolver. */
export function useLeadProductTypeOptions() {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const { data: types } = leadProductTypesHooks.useList(profile?.org_id)
  return {
    productTypes: types ?? [],
    activeProductTypes: (types ?? []).filter((p) => p.is_active),
    label: (key: string) => leadProductTypeLabel(key, types, t, i18n.language),
  }
}
