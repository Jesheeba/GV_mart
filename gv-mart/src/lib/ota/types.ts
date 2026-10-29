export type OtaChannel = "production" | "technician-test"

// Fields that get signed, in this exact order — the publish script and the
// in-app verifier both build the same pipe-joined string from these, so
// neither side depends on JSON key ordering.
export type OtaManifestPayload = {
  channel: OtaChannel
  version: string
  buildNumber: number
  url: string
  checksum: string
  minNativeBuild: number
  frozen: boolean
  publishedAt: string
}

export type OtaManifest = OtaManifestPayload & {
  signature: string
}

export type OtaCheckResult =
  | { status: "skipped-web" }
  | { status: "offline" }
  | { status: "invalid-signature" }
  | { status: "frozen" }
  | { status: "store-update-required"; minNativeBuild: number; currentNativeBuild: number }
  | { status: "up-to-date" }
  | { status: "queued"; buildNumber: number; version: string }
  | { status: "error"; message: string }
