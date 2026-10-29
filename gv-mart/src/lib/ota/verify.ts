import nacl from "tweetnacl"
import { OTA_PUBLIC_KEY_BASE64URL } from "./publicKey"
import type { OtaManifest, OtaManifestPayload } from "./types"

function base64UrlToBytes(b64url: string): Uint8Array {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(b64url.length / 4) * 4, "=")
  const binary = atob(b64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

// Must match scripts/ota-publish.mjs exactly — a pipe-joined canonical
// string rather than JSON.stringify, so neither side can drift on key
// ordering or whitespace.
export function canonicalManifestString(m: OtaManifestPayload): string {
  return [m.channel, m.version, String(m.buildNumber), m.url, m.checksum, String(m.minNativeBuild), String(m.frozen), m.publishedAt].join("|")
}

const publicKeyBytes = base64UrlToBytes(OTA_PUBLIC_KEY_BASE64URL)

export function verifyManifestSignature(manifest: OtaManifest): boolean {
  const { signature, ...payload } = manifest
  if (!signature) return false
  const message = new TextEncoder().encode(canonicalManifestString(payload))
  let signatureBytes: Uint8Array
  try {
    signatureBytes = base64ToBytes(signature)
  } catch {
    return false
  }
  if (signatureBytes.length !== 64) return false
  return nacl.sign.detached.verify(message, signatureBytes, publicKeyBytes)
}
