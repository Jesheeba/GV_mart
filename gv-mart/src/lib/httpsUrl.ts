/**
 * Mirrors the database rule on spare_videos.url (constraint spare_videos_url_https_check):
 * `^https://[^[:space:]]+$`, case-insensitive. Keep the two in step.
 */
export function isHttpsUrl(value: string): boolean {
  return /^https:\/\/\S+$/i.test(value)
}
