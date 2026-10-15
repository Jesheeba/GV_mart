/**
 * Colour-per-user for the task calendar and list. `profiles.colour` (20261102100000) is nullable — a user who
 * hasn't picked one yet (there is no colour-picker screen yet; this is read-only for now) falls back to a stable
 * colour derived from their profile id, so two renders of the same user always agree without a round trip.
 */
export function userColour(profileId: string, explicitColour?: string | null): string {
  if (explicitColour) return explicitColour
  let hash = 0
  for (let i = 0; i < profileId.length; i++) {
    hash = (hash * 31 + profileId.charCodeAt(i)) >>> 0
  }
  const hue = hash % 360
  return `hsl(${hue}, 60%, 45%)`
}
