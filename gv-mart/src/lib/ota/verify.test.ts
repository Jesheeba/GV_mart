import nacl from "tweetnacl"
import { describe, expect, it } from "vitest"
import { canonicalManifestString, verifyManifestSignature } from "./verify"
import { OTA_PUBLIC_KEY_BASE64URL } from "./publicKey"
import type { OtaManifest, OtaManifestPayload } from "./types"

// This test's own keypair — NOT the real one in _local_only/secrets — so it
// can prove verifyManifestSignature rejects a manifest signed by anyone
// other than the key baked into publicKey.ts.
const foreignPayload: OtaManifestPayload = {
  channel: "technician-test",
  version: "2026-10-29-b1",
  buildNumber: 1,
  url: "https://example.com/ota/technician-test/bundle.zip",
  checksum: "abc123",
  minNativeBuild: 1,
  frozen: false,
  publishedAt: "2026-10-29T00:00:00.000Z",
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ""
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary)
}

function signWithForeignKey(payload: OtaManifestPayload): OtaManifest {
  const foreignKeyPair = nacl.sign.keyPair()
  const message = new TextEncoder().encode(canonicalManifestString(payload))
  const signature = bytesToBase64(nacl.sign.detached(message, foreignKeyPair.secretKey))
  return { ...payload, signature }
}

describe("verifyManifestSignature", () => {
  it("rejects a manifest signed by a different key", () => {
    const manifest = signWithForeignKey(foreignPayload)
    expect(verifyManifestSignature(manifest)).toBe(false)
  })

  it("rejects a manifest whose payload was tampered with after signing", () => {
    const manifest = signWithForeignKey(foreignPayload)
    const tampered = { ...manifest, buildNumber: 999 }
    expect(verifyManifestSignature(tampered)).toBe(false)
  })

  it("rejects a manifest with no signature", () => {
    expect(verifyManifestSignature({ ...foreignPayload, signature: "" })).toBe(false)
  })

  it("sanity: OTA_PUBLIC_KEY_BASE64URL is well-formed", () => {
    expect(OTA_PUBLIC_KEY_BASE64URL).toMatch(/^[A-Za-z0-9_-]{43}$/)
  })
})
