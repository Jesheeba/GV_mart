import { useState } from "react"
import { useTranslation } from "react-i18next"
import { PlayCircle } from "lucide-react"
import { getYoutubeThumbnail } from "@/lib/video"
import type { Enums } from "@/types/database"

/**
 * Replaces a raw `<a href={video.url}>{video.url}</a>` link with an actual
 * video-preview card. `video_library` has no title/thumbnail columns (just
 * topic + url), so the thumbnail is derived client-side for YouTube links
 * (the common case) and everything else — including a thumbnail that fails
 * to load — falls back to a plain topic-colored tile. Stays a normal
 * external link (opens in a new tab); no in-app lightbox/player, since no
 * Dialog primitive exists anywhere in this codebase yet and handing off to
 * the native YouTube app is a perfectly good outcome on mobile.
 */
export function VideoCard({ url, topic, index }: { url: string; topic: Enums<"enquiry_type">; index: number }) {
  const { t } = useTranslation()
  const thumbnail = getYoutubeThumbnail(url)
  const [thumbnailFailed, setThumbnailFailed] = useState(false)
  const caption = t("customerApp.productEnquiry.videoCaption", { topic: t(`customerApp.productEnquiry.topics.${topic}`), index })

  return (
    <a
      href={url}
      target="_blank"
      rel="noreferrer"
      className="block overflow-hidden rounded-xl border border-border transition-colors hover:bg-surface-alt/60"
    >
      <div className="relative flex aspect-video w-full items-center justify-center bg-accent-soft">
        {thumbnail && !thumbnailFailed ? (
          <img src={thumbnail} alt="" className="size-full object-cover" onError={() => setThumbnailFailed(true)} />
        ) : null}
        <span className="absolute flex size-11 items-center justify-center rounded-full bg-ink/80 text-white">
          <PlayCircle className="size-6" />
        </span>
      </div>
      <p className="truncate px-3 py-2 text-sm font-medium text-text">{caption}</p>
    </a>
  )
}
