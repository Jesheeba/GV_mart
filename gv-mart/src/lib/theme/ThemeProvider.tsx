import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react"
import { Capacitor } from "@capacitor/core"
import { StatusBar, Style } from "@capacitor/status-bar"
import { router } from "@/router"

export type Theme = "light" | "dark"

const THEME_STORAGE_KEY = "gv-mart-theme"
const TECHNICIAN_PATH_PREFIX = "/technician"

type ThemeContextValue = {
  theme: Theme
  setTheme: (theme: Theme) => void
  toggleTheme: () => void
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

function getStoredTheme(): Theme {
  if (typeof window === "undefined") return "light"
  const stored = window.localStorage.getItem(THEME_STORAGE_KEY)
  return stored === "dark" ? "dark" : "light"
}

function isTechnicianPath(pathname: string): boolean {
  return pathname === TECHNICIAN_PATH_PREFIX || pathname.startsWith(`${TECHNICIAN_PATH_PREFIX}/`)
}

/**
 * Finexy is light-first (cream canvas). Dark mode is offered only for the
 * outdoor Technician App (design system §2.6/§3.13) — Admin and Customer are
 * light-only. `storedTheme` tracks the technician's toggle preference, but it
 * only ever reaches <html> (and only ever gets reported to consumers) while
 * the active route is under /technician, tracked via `router.subscribe`
 * since this provider sits above the router in main.tsx and can't use
 * react-router's location hooks. So Admin/Customer always render light, even
 * if a technician previously toggled dark on the same browser/origin.
 */
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [storedTheme, setStoredTheme] = useState<Theme>(getStoredTheme)
  const [pathname, setPathname] = useState<string>(() => router.state.location.pathname)

  useEffect(() => {
    return router.subscribe((state) => setPathname(state.location.pathname))
  }, [])

  const effectiveTheme: Theme = isTechnicianPath(pathname) ? storedTheme : "light"

  useEffect(() => {
    document.documentElement.classList.toggle("dark", effectiveTheme === "dark")
    if (Capacitor.isNativePlatform()) {
      void StatusBar.setStyle({ style: effectiveTheme === "dark" ? Style.Dark : Style.Light })
    }
  }, [effectiveTheme])

  useEffect(() => {
    window.localStorage.setItem(THEME_STORAGE_KEY, storedTheme)
  }, [storedTheme])

  const value = useMemo<ThemeContextValue>(
    () => ({
      theme: effectiveTheme,
      setTheme: setStoredTheme,
      toggleTheme: () => setStoredTheme((t) => (t === "light" ? "dark" : "light")),
    }),
    [effectiveTheme]
  )

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme() {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error("useTheme must be used within a ThemeProvider")
  return ctx
}
