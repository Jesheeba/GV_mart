import { useCallback, useMemo, useRef, useState, type ReactNode } from "react"
import { createPortal } from "react-dom"
import { CheckCircle2, Info, TriangleAlert, X } from "lucide-react"
import { cn } from "@/lib/utils"
import { ToastContext, type ToastContextValue, type ToastRecord, type ToastVariant } from "./toast-context"

// Long enough to read a short sentence, short enough not to pile up if
// several mutations fail back-to-back.
const AUTO_DISMISS_MS = 4000

/**
 * Minimal context + portal toast system (no dependency — this codebase has
 * none). Mount once at the app root via <ToastProvider> (see main.tsx, it
 * renders <Toaster> internally) so `useToast()` — from ./toast-context —
 * works from any of the three role-scoped route trees
 * (admin/technician/customer).
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastRecord[]>([])
  // Tracks pending auto-dismiss timers so a manual (tap-to-dismiss) close
  // also clears the timer instead of leaving a stray setState-after-unmount.
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>())

  const dismiss = useCallback((id: string) => {
    setToasts((prev) => prev.filter((item) => item.id !== id))
    const timer = timers.current.get(id)
    if (timer) {
      clearTimeout(timer)
      timers.current.delete(id)
    }
  }, [])

  const push = useCallback(
    (message: string, variant: ToastVariant) => {
      const id = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`
      setToasts((prev) => [...prev, { id, message, variant }])
      timers.current.set(
        id,
        setTimeout(() => dismiss(id), AUTO_DISMISS_MS)
      )
    },
    [dismiss]
  )

  const value = useMemo<ToastContextValue>(
    () => ({
      toast: {
        success: (message: string) => push(message, "success"),
        error: (message: string) => push(message, "error"),
        info: (message: string) => push(message, "info"),
        warning: (message: string) => push(message, "warning"),
      },
    }),
    [push]
  )

  return (
    <ToastContext.Provider value={value}>
      {children}
      <Toaster toasts={toasts} onDismiss={dismiss} />
    </ToastContext.Provider>
  )
}

const VARIANT_ICON: Record<ToastVariant, typeof CheckCircle2> = {
  success: CheckCircle2,
  error: TriangleAlert,
  warning: TriangleAlert,
  info: Info,
}

const VARIANT_ICON_CLASS: Record<ToastVariant, string> = {
  success: "text-success",
  error: "text-danger",
  warning: "text-warning",
  info: "text-info",
}

function Toaster({ toasts, onDismiss }: { toasts: ToastRecord[]; onDismiss: (id: string) => void }) {
  // Fixed to the viewport, not any particular shell — sits above the
  // technician/customer bottom tab bar (which reserves ~5rem and is z-40)
  // and above the admin sidebar/header, via extra bottom padding + a
  // higher z-index than anything else in the app (modals/dropdowns top
  // out at z-50).
  return createPortal(
    <div
      role="region"
      aria-live="polite"
      aria-label="Notifications"
      className="pointer-events-none fixed inset-x-0 bottom-0 z-[100] flex flex-col items-center gap-2 px-4 pb-[calc(6rem+env(safe-area-inset-bottom))]"
    >
      {toasts.map((item) => {
        const Icon = VARIANT_ICON[item.variant]
        return (
          <button
            key={item.id}
            type="button"
            onClick={() => onDismiss(item.id)}
            className="pointer-events-auto flex w-full max-w-sm animate-in items-start gap-2.5 rounded-card border border-border bg-surface px-4 py-3 text-left text-sm text-text shadow-[0_1px_2px_rgba(26,26,26,0.04),0_8px_24px_-12px_rgba(26,26,26,0.08)] fade-in-0 slide-in-from-bottom-2"
          >
            <Icon className={cn("mt-0.5 size-4 shrink-0", VARIANT_ICON_CLASS[item.variant])} />
            <span className="min-w-0 flex-1 break-words">{item.message}</span>
            <X className="mt-0.5 size-3.5 shrink-0 text-text-muted" />
          </button>
        )
      })}
    </div>,
    document.body
  )
}
