/**
 * Video language (2026-10-14). `product_videos`, `spare_videos` and `video_library` carry a nullable `language`
 * column: NULL means "any language", so rows saved before the column existed keep working unchanged.
 * Nothing reads the language at send time yet; the admin forms only record it.
 */
export const VIDEO_LANGUAGES = ["en", "ta"] as const
export type VideoLanguage = (typeof VIDEO_LANGUAGES)[number]

/** A form value ("" = any language) to the stored value; anything unrecognised becomes NULL, never a bad string. */
export function toVideoLanguage(value: string | null | undefined): VideoLanguage | null {
  return (VIDEO_LANGUAGES as readonly string[]).includes(value ?? "") ? (value as VideoLanguage) : null
}
