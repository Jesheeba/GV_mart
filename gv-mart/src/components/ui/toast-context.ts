import { createContext, useContext } from "react"

export type ToastVariant = "success" | "error" | "info" | "warning"

export type ToastRecord = {
  id: string
  message: string
  variant: ToastVariant
}

export type ToastApi = {
  success: (message: string) => void
  error: (message: string) => void
  info: (message: string) => void
  warning: (message: string) => void
}

export type ToastContextValue = { toast: ToastApi }

// Split into its own module (rather than living in toast.tsx alongside the
// provider/Toaster components) purely to keep toast.tsx a components-only
// file for Fast Refresh.
export const ToastContext = createContext<ToastContextValue | null>(null)

export function useToast(): ToastContextValue {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error("useToast must be used within a ToastProvider")
  return ctx
}
