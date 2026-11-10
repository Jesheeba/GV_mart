import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { GoogleLinkAccountCard } from "@/app/auth/GoogleLinkAccountCard"
import { useAuth } from "@/hooks/useAuth"
import { classifyOnboardError } from "@/lib/auto-onboard"
import { customerAutoOnboard } from "@/services/auth"

/**
 * Renders in place of the old static "contact the shop" dead-end
 * (20261130100001_customer_auto_onboard_rpc.sql replaces
 * link_customer_google_account for the common case). Calls the RPC once on
 * mount — it takes no arguments, the server reads the caller's own
 * Google-verified email itself — then:
 *   - on success: invalidates the ["profile", userId] query. LoginPage
 *     shares that same query, so it re-renders with `profile` set and
 *     navigates away on its own (see LoginPage's `if (profile) return
 *     <Navigate ...>` branch) — this component never has to navigate
 *     itself.
 *   - on a `staff_account` refusal, or any other RPC error: shows
 *     GoogleLinkAccountCard with a message matched to which one it was.
 */
export function CustomerAutoOnboardGate() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const { session } = useAuth()

  const onboard = useMutation({
    mutationFn: customerAutoOnboard,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profile", session?.user.id] })
    },
  })

  useEffect(() => {
    onboard.mutate()
    // Runs exactly once per mount — this component only ever mounts for the
    // one first-time-Google-sign-in state LoginPage routes into it for.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  if (onboard.isError) {
    return <GoogleLinkAccountCard reason={classifyOnboardError(onboard.error)} />
  }

  // Pending, or succeeded and waiting for the invalidated profile query to
  // land and carry LoginPage to its own Navigate branch.
  return <FullPageLoader label={t("common.loading")} />
}
