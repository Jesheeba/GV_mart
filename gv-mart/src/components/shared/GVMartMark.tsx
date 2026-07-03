/**
 * GV Mart brand mark — a stylized petal/splash burst over water-wave lines
 * (water purifiers/RO are the core product line). Recreated as SVG from the
 * client's logo artwork since only the rendered image was available, not
 * the source file.
 */
export function GVMartMark({
  className,
  variant = "brand",
}: {
  className?: string
  /** "brand" = full orange/gray palette (light backgrounds). "mono" = a
   * single currentColor fill/stroke, for badges on a solid accent/ink bg. */
  variant?: "brand" | "mono"
}) {
  const mono = variant === "mono"
  return (
    <svg viewBox="0 0 100 90" className={className} fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      {/* petals, fanning up from a shared base point */}
      <path d="M50 46 C38 40 30 26 34 12 C48 14 56 28 54 42 Z" fill={mono ? "currentColor" : "#4D4D4D"} opacity={mono ? 0.75 : 1} />
      <path d="M50 46 C34 44 20 34 18 20 C33 16 47 26 50 40 Z" fill={mono ? "currentColor" : "#F5612C"} />
      <path d="M50 46 C46 30 52 14 66 6 C74 18 70 34 58 42 Z" fill={mono ? "currentColor" : "#F5612C"} />
      <path d="M50 46 C58 32 74 24 88 28 C86 42 72 50 58 46 Z" fill={mono ? "currentColor" : "#4D4D4D"} opacity={mono ? 0.75 : 1} />
      <path d="M50 46 C62 40 78 40 88 48 C82 58 66 60 56 52 Z" fill={mono ? "currentColor" : "#F5612C"} />
      {/* wave / ripple lines */}
      <path d="M14 58 C28 50 40 50 50 56 C62 62 74 62 88 54" stroke={mono ? "currentColor" : "#F5612C"} strokeWidth="4" strokeLinecap="round" opacity={mono ? 0.9 : 1} />
      <path d="M12 66 C26 58 40 58 50 64 C62 70 76 70 90 62" stroke={mono ? "currentColor" : "#4D4D4D"} strokeWidth="4" strokeLinecap="round" opacity={mono ? 0.7 : 1} />
      {!mono ? <path d="M16 74 C29 68 40 68 50 73 C61 78 73 78 86 71" stroke="#C9C4BB" strokeWidth="4" strokeLinecap="round" /> : null}
    </svg>
  )
}
