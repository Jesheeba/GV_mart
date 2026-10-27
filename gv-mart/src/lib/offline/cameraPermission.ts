/**
 * Item 9 (camera-only capture) — the technician photo inputs are plain
 * `<input type=file accept="image/*" capture="environment">` elements (see
 * PhotoCapture.tsx for why no camera library/getUserMedia was added: it
 * works fully offline with no extra permission dance beyond the input
 * itself). That means there is no JS-level `NotAllowedError` to catch the
 * way `getUserMedia()` would throw one — the OS camera app simply fails to
 * open, or the input's change event never fires, when permission is denied.
 *
 * This helper lets us proactively check (and react to) camera permission
 * state using the standard Permissions API where the browser supports a
 * "camera" descriptor, so the technician gets an explicit message instead
 * of a dialog that silently does nothing.
 */
export type CameraPermissionState = "granted" | "denied" | "prompt" | "unsupported"

export async function getCameraPermissionState(): Promise<CameraPermissionState> {
  try {
    if (!navigator.permissions?.query) return "unsupported"
    const status = await navigator.permissions.query({ name: "camera" as PermissionName })
    return status.state as CameraPermissionState
  } catch {
    // Some browsers (notably Safari/iOS and Firefox) don't recognise the
    // "camera" permission name and throw a TypeError from query() — treat
    // that the same as "unsupported" so those platforms fall back to the
    // input's native behavior unchanged.
    return "unsupported"
  }
}
