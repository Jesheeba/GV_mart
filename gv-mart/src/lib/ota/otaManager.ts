import { Capacitor } from "@capacitor/core"
import { App as CapacitorApp } from "@capacitor/app"
import { CapacitorUpdater } from "@capgo/capacitor-updater"
import { setStoreUpdateRequired } from "./storeUpdateGate"
import { verifyManifestSignature } from "./verify"
import type { OtaCheckResult, OtaChannel, OtaManifest } from "./types"

const CHANNEL_STORAGE_KEY = "gvmart.ota.channel"
const APPLIED_BUILD_STORAGE_KEY = "gvmart.ota.appliedBuild"

export function getOtaChannel(): OtaChannel {
  try {
    const stored = localStorage.getItem(CHANNEL_STORAGE_KEY)
    if (stored === "technician-test") return stored
  } catch {
    // localStorage can throw in locked-down webviews — fall back silently.
  }
  return "production"
}

export function setOtaChannel(channel: OtaChannel) {
  try {
    localStorage.setItem(CHANNEL_STORAGE_KEY, channel)
  } catch {
    // Best-effort; worst case the device stays on "production".
  }
}

function getAppliedBuild(): number {
  try {
    return Number(localStorage.getItem(APPLIED_BUILD_STORAGE_KEY) ?? "0") || 0
  } catch {
    return 0
  }
}

function setAppliedBuild(buildNumber: number) {
  try {
    localStorage.setItem(APPLIED_BUILD_STORAGE_KEY, String(buildNumber))
  } catch {
    // Non-fatal: worst case we re-download an already-applied build once.
  }
}

async function fetchManifest(channel: OtaChannel): Promise<OtaManifest | null> {
  const url = `${location.origin}/ota/${channel}/manifest.json?t=${Date.now()}`
  const response = await fetch(url, { cache: "no-store" })
  if (!response.ok) return null
  return (await response.json()) as OtaManifest
}

/**
 * Checks for and silently queues an OTA update. Never throws, never blocks —
 * call this on app start and on resume. A queued update is applied by
 * CapacitorUpdater's `next()` only when the app backgrounds or relaunches,
 * so it never interrupts a technician mid-visit.
 */
export async function checkForOtaUpdate(): Promise<OtaCheckResult> {
  if (!Capacitor.isNativePlatform()) return { status: "skipped-web" }

  try {
    const channel = getOtaChannel()
    const manifest = await fetchManifest(channel)
    if (!manifest) return { status: "offline" }

    if (!verifyManifestSignature(manifest)) {
      console.error("[ota] manifest signature failed verification — refusing to apply")
      return { status: "invalid-signature" }
    }

    if (manifest.frozen) return { status: "frozen" }

    const info = await CapacitorApp.getInfo()
    const currentNativeBuild = Number(info.build) || 0
    if (currentNativeBuild < manifest.minNativeBuild) {
      setStoreUpdateRequired(true)
      return { status: "store-update-required", minNativeBuild: manifest.minNativeBuild, currentNativeBuild }
    }
    setStoreUpdateRequired(false)

    if (manifest.buildNumber <= getAppliedBuild()) return { status: "up-to-date" }

    const downloaded = await CapacitorUpdater.download({
      url: manifest.url,
      version: manifest.version,
      checksum: manifest.checksum,
    })
    await CapacitorUpdater.next({ id: downloaded.id })
    setAppliedBuild(manifest.buildNumber)
    return { status: "queued", buildNumber: manifest.buildNumber, version: manifest.version }
  } catch (error) {
    console.error("[ota] update check failed", error)
    return { status: "error", message: error instanceof Error ? error.message : String(error) }
  }
}

/** Must run before any network call, per plugin docs — confirms the JS bundle itself loaded. */
export async function notifyOtaAppReady(): Promise<void> {
  if (!Capacitor.isNativePlatform()) return
  try {
    await CapacitorUpdater.notifyAppReady()
  } catch (error) {
    console.error("[ota] notifyAppReady failed", error)
  }
}

export type OtaVersionInfo = {
  nativeVersionName: string
  nativeBuild: string
  bundleId: string
  bundleVersion: string
  channel: OtaChannel
}

export async function getOtaVersionInfo(): Promise<OtaVersionInfo | null> {
  if (!Capacitor.isNativePlatform()) return null
  try {
    const [info, bundle] = await Promise.all([CapacitorApp.getInfo(), CapacitorUpdater.current()])
    return {
      nativeVersionName: info.version,
      nativeBuild: info.build,
      bundleId: bundle.bundle.id,
      bundleVersion: bundle.bundle.version,
      channel: getOtaChannel(),
    }
  } catch (error) {
    console.error("[ota] failed to read version info", error)
    return null
  }
}
