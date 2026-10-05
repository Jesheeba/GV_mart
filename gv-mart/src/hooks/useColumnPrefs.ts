import { useCallback, useEffect, useState } from "react"
import { useProfile } from "@/hooks/useProfile"

type PrefsEnvelope = { data: string[]; updatedAt: number }

function read<K extends string>(storageKey: string, allKeys: readonly K[], defaults: readonly K[]): Set<K> {
  try {
    const raw = localStorage.getItem(storageKey)
    if (raw) {
      const parsed = JSON.parse(raw) as PrefsEnvelope
      // Drop keys the catalog no longer has, so a renamed/removed column in a
      // later release can't leave a ghost entry behind.
      if (Array.isArray(parsed.data)) return new Set(allKeys.filter((k) => parsed.data.includes(k)))
    }
  } catch {
    // Corrupt/unavailable storage — fall back to defaults.
  }
  return new Set(defaults)
}

/**
 * Per-admin, per-report column visibility, persisted in localStorage using
 * the same `{ data, updatedAt }` envelope + try/catch degradation as
 * useLocalDraft. `allKeys` is the fixed catalog of columns the report can
 * show (its order is the display order); `defaults` is what shows until the
 * admin changes anything. This is a visibility toggle over a fixed catalog,
 * not a custom report builder.
 */
export function useColumnPrefs<K extends string>(reportKey: string, allKeys: readonly K[], defaults: readonly K[]) {
  const { data: profile } = useProfile()
  const storageKey = `gv.reportColumns.${profile?.id ?? "anon"}.${reportKey}`
  const [state, setState] = useState(() => ({ key: storageKey, visible: read(storageKey, allKeys, defaults) }))

  // The profile id arrives async, so re-read when the storage key changes.
  useEffect(() => {
    setState((s) => (s.key === storageKey ? s : { key: storageKey, visible: read(storageKey, allKeys, defaults) }))
    // allKeys/defaults are module-level constants at every call site.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storageKey])

  const persist = useCallback(
    (next: Set<K>) => {
      setState({ key: storageKey, visible: next })
      try {
        const envelope: PrefsEnvelope = { data: [...next], updatedAt: Date.now() }
        localStorage.setItem(storageKey, JSON.stringify(envelope))
      } catch {
        // Storage full/unavailable — the choice just won't survive a reload.
      }
    },
    [storageKey]
  )

  const toggle = useCallback(
    (key: K) => {
      const next = new Set(state.visible)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      persist(next)
    },
    [state.visible, persist]
  )

  const reset = useCallback(() => {
    try {
      localStorage.removeItem(storageKey)
    } catch {
      // ignore
    }
    setState({ key: storageKey, visible: new Set(defaults) })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storageKey])

  const isVisible = useCallback((key: K) => state.visible.has(key), [state.visible])

  return { visible: state.visible, isVisible, toggle, reset }
}
