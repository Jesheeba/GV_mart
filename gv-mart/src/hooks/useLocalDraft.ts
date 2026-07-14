import { useEffect, useRef, useState } from "react"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"

type DraftEnvelope<T> = { data: T; updatedAt: number }

/**
 * Lightweight localStorage-backed draft persistence for the admin/customer
 * multi-step wizards (NewSalePage, NewComplaintPage, BookServicePage).
 * These apps aren't offline-first — unlike the technician app's Dexie-backed
 * `visitFormDrafts` table (see src/app/technician/onsite/OnSiteVisitPage.tsx
 * and src/lib/offline/db.ts) — so a debounced JSON blob in localStorage is
 * enough to survive an accidental navigate-away-and-back mid-wizard without
 * losing typed-but-unsaved input.
 *
 * Pass `key = null` to disable persistence entirely (e.g. a wizard reached
 * via a one-shot prefill like "convert this quotation" or "new ticket for
 * this customer", where resurrecting an unrelated older draft over a fresh
 * prefill would be actively wrong).
 *
 * Usage: build a plain-object snapshot of the wizard's restorable state and
 * pass it in every render. On mount this restores whatever was last saved
 * for `key` into `restoredDraft` exactly once — the caller applies it
 * field-by-field into its own useState/react-hook-form calls (only
 * overwriting fields that were actually present), the same convention
 * OnSiteVisitPage's draft restore uses.
 */
export function useLocalDraft<T extends object>(key: string | null, snapshot: T) {
  const [hydrated, setHydrated] = useState(false)
  const [wasRestored, setWasRestored] = useState(false)
  const [restoredDraft, setRestoredDraft] = useState<T | null>(null)
  const hydratingKeyRef = useRef<string | null>(null)
  // Set right before discardDraft() clears storage — without this, the
  // still-active debounced autosave effect below would write the current
  // (about-to-be-reset-by-the-caller) snapshot right back to localStorage
  // moments after the user explicitly discarded it.
  const suppressNextWriteRef = useRef(false)

  useEffect(() => {
    if (!key || hydratingKeyRef.current === key) {
      if (!key) setHydrated(true)
      return
    }
    hydratingKeyRef.current = key
    try {
      const raw = localStorage.getItem(key)
      if (raw) {
        const parsed = JSON.parse(raw) as DraftEnvelope<T>
        setRestoredDraft(parsed.data)
        setWasRestored(true)
      }
    } catch {
      // Corrupt/unavailable storage — proceed as if there were no draft.
    } finally {
      setHydrated(true)
    }
  }, [key])

  const debouncedSnapshot = useDebouncedValue(JSON.stringify(snapshot), 500)

  useEffect(() => {
    if (!key || !hydrated) return
    if (suppressNextWriteRef.current) {
      suppressNextWriteRef.current = false
      return
    }
    try {
      const envelope: DraftEnvelope<T> = { data: JSON.parse(debouncedSnapshot), updatedAt: Date.now() }
      localStorage.setItem(key, JSON.stringify(envelope))
    } catch {
      // Storage full/unavailable/private-mode — the draft just won't
      // persist this tick, which is a safe degradation, not a crash.
    }
  }, [debouncedSnapshot, key, hydrated])

  function discardDraft() {
    if (key) {
      try {
        localStorage.removeItem(key)
      } catch {
        // ignore
      }
    }
    suppressNextWriteRef.current = true
    setWasRestored(false)
    setRestoredDraft(null)
  }

  function clearDraft() {
    if (key) {
      try {
        localStorage.removeItem(key)
      } catch {
        // ignore
      }
    }
  }

  return { hydrated, restoredDraft, wasRestored, discardDraft, clearDraft }
}
