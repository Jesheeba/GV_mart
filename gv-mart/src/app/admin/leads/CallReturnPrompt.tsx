import { useEffect, useState } from "react"
import { LogOutcomeSheet, type OutcomeSheetLead } from "./LogOutcomeSheet"
import { markLeft, takeReturnedCall } from "@/lib/call-return"

/**
 * Mounted once in the admin shell for master / sales_admin: after the user
 * taps Call on a lead and returns to the app (page hidden/blurred, then
 * visible/focused again), the Log Outcome sheet opens for that lead.
 */
export function CallReturnPrompt() {
  const [lead, setLead] = useState<OutcomeSheetLead | null>(null)
  const [open, setOpen] = useState(false)

  useEffect(() => {
    function onAway() {
      markLeft()
    }
    function onBack() {
      const c = takeReturnedCall()
      if (c) {
        setLead({ id: c.id, name: c.name, mobile: c.mobile, status: c.status })
        setOpen(true)
      }
    }
    function onVisibility() {
      if (document.visibilityState === "hidden") onAway()
      else onBack()
    }
    document.addEventListener("visibilitychange", onVisibility)
    window.addEventListener("blur", onAway)
    window.addEventListener("focus", onBack)
    return () => {
      document.removeEventListener("visibilitychange", onVisibility)
      window.removeEventListener("blur", onAway)
      window.removeEventListener("focus", onBack)
    }
  }, [])

  return <LogOutcomeSheet lead={lead} open={open} onOpenChange={setOpen} defaultChannel="call" />
}
