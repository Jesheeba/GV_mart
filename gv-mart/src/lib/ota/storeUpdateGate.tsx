import { useSyncExternalStore } from "react"
import { useTranslation } from "react-i18next"
import { Download } from "lucide-react"
import { Button } from "@/components/ui/button"

// Minimal external store (no context provider needed) so otaManager can
// flip this from deep inside a fire-and-forget check, and the gate below
// — mounted once, outside the router, like ErrorBoundary — just reflects it.
let required = false
const listeners = new Set<() => void>()

export function setStoreUpdateRequired(value: boolean) {
  if (required === value) return
  required = value
  listeners.forEach((l) => l())
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function getSnapshot() {
  return required
}

const PLAY_STORE_URL = "market://details?id=com.gvmart.app"

/** Blocks the app when the installed native shell is too old for the latest OTA bundle. */
export function StoreUpdateGate({ children }: { children: React.ReactNode }) {
  const { t } = useTranslation()
  const isRequired = useSyncExternalStore(subscribe, getSnapshot)

  if (!isRequired) return <>{children}</>

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-bg px-6 text-center">
      <Download className="size-8 text-accent" />
      <p className="text-base font-semibold text-text">{t("technician.profile.storeUpdateRequired")}</p>
      <Button type="button" onClick={() => window.open(PLAY_STORE_URL, "_self")}>
        {t("technician.profile.openPlayStore")}
      </Button>
    </div>
  )
}
