import { useState } from "react"
import { Package } from "lucide-react"
import { productImagePublicUrl } from "@/services/productMedia"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 4 — detail-page hero image.
 * Deliberately not a carousel (only one image is planned to matter here —
 * the primary — even though a product can have several); graceful
 * image-load fallback mirrors VideoCard.tsx's onError-swap-to-placeholder
 * pattern for broken thumbnails.
 */
export function ProductPhotoHero({ images, name }: { images: { storage_path: string; is_primary: boolean }[]; name: string }) {
  const primary = images.find((img) => img.is_primary) ?? images[0]
  const [failed, setFailed] = useState(false)

  if (!primary || failed) {
    return (
      <div className="mx-auto flex aspect-square w-full max-w-[800px] items-center justify-center rounded-xl bg-surface-alt text-text-muted">
        <Package className="size-12" />
      </div>
    )
  }

  return (
    <img
      src={productImagePublicUrl(primary.storage_path)}
      alt={name}
      className="mx-auto aspect-square w-full max-w-[800px] rounded-xl object-cover"
      onError={() => setFailed(true)}
    />
  )
}
