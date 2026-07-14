/**
 * The 5-color avatar-chip rotation used throughout the Claude-Design mock
 * (customer list rows, product/family cards) — literal hex pairs from the
 * design, picked deterministically per name so the same person always gets
 * the same color instead of a random one on every render.
 */
const AVATAR_PALETTE = [
  { bg: "#FDE7DD", fg: "#F5612C" },
  { bg: "#E6EEFC", fg: "#2E6BE6" },
  { bg: "#E2F3EA", fg: "#16855B" },
  { bg: "#FCEAEA", fg: "#E5484D" },
  { bg: "#F0EBE3", fg: "#1A1A1A" },
] as const

export function avatarPalette(seed: string): { bg: string; fg: string } {
  let hash = 0
  for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) >>> 0
  return AVATAR_PALETTE[hash % AVATAR_PALETTE.length]
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/)
  return ((parts[0]?.[0] ?? "") + (parts[1]?.[0] ?? "")).toUpperCase()
}
