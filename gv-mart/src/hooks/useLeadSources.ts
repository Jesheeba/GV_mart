import { useTranslation } from "react-i18next"
import { useProfile } from "@/hooks/useProfile"
import { leadSourcesHooks } from "@/hooks/useMasters"
import { leadSourceLabel } from "@/lib/lead-sources"

/** Org lead sources plus a label resolver that works for built-in and custom keys. */
export function useLeadSourceOptions() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const { data: sources } = leadSourcesHooks.useList(profile?.org_id)
  return {
    sources: sources ?? [],
    /** Active only — what a "new lead" dropdown should offer. */
    activeSources: (sources ?? []).filter((s) => s.is_active),
    label: (key: string) => leadSourceLabel(key, sources, t),
  }
}
