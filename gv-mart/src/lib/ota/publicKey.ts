// Ed25519 public key used to verify OTA manifests. Safe to be public — it
// only lets this app CHECK a manifest's signature, never create one.
// Matching private key lives outside the repo; see
// `_local_only/secrets/ota/` (not in this checkout — see the OTA release
// report for the full key-rotation procedure).
export const OTA_PUBLIC_KEY_BASE64URL = "Pd2eWPh9mheQNCsNaBRb-YdRdzvuNkXikPWSC2PMQK4"
