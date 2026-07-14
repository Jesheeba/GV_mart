/**
 * Client-side YouTube thumbnail derivation — `video_library` only ever
 * stores a bare `topic` + `url` (no title/thumbnail columns), so any visual
 * upgrade over a raw link has to work from the URL alone. YouTube serves
 * thumbnails from a public, unauthenticated, no-quota endpoint keyed by
 * video id, which covers the common case for admin-pasted links without
 * needing a schema change.
 */

const YOUTUBE_ID_PATTERNS = [
  /(?:youtube\.com\/watch\?v=)([\w-]{11})/,
  /(?:youtu\.be\/)([\w-]{11})/,
  /(?:youtube\.com\/shorts\/)([\w-]{11})/,
  /(?:youtube\.com\/embed\/)([\w-]{11})/,
]

export function getYoutubeVideoId(url: string): string | null {
  for (const pattern of YOUTUBE_ID_PATTERNS) {
    const match = url.match(pattern)
    if (match) return match[1]
  }
  return null
}

export function getYoutubeThumbnail(url: string): string | null {
  const id = getYoutubeVideoId(url)
  return id ? `https://img.youtube.com/vi/${id}/hqdefault.jpg` : null
}
