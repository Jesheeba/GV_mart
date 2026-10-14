import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Plus, Trash2, Video } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { VideoLanguageSelect } from "@/components/shared/VideoLanguageSelect"
import { useCreateSpareVideo, useDeleteSpareVideo, useSpareVideos, useUpdateSpareVideo } from "@/hooks/useMasters"
import { isHttpsUrl } from "@/lib/httpsUrl"
import type { VideoLanguage } from "@/lib/videoLanguage"

// Supabase/PostgREST rejections are not `instanceof Error` — same helper as ProductMediaPanel, duplicated for the same
// reason (small, not worth a shared utility).
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

/**
 * Videos for one spare (2026-10-14). Spares had no video storage; this mirrors the Videos tab of ProductMediaPanel and
 * adds the nullable language. Opened from a row action in Masters > Spares (SparesTab.tsx). Master only (RLS).
 */
export function SpareVideosPanel({
  orgId,
  spareId,
  spareName,
  onClose,
}: {
  orgId: string | undefined
  spareId: string
  spareName: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { data: videos, isLoading } = useSpareVideos(spareId)
  const createMut = useCreateSpareVideo(spareId)
  const updateMut = useUpdateSpareVideo(spareId)
  const deleteMut = useDeleteSpareVideo(spareId)
  const [url, setUrl] = useState("")
  const [title, setTitle] = useState("")
  const [language, setLanguage] = useState<VideoLanguage | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function handleAdd() {
    if (!url.trim() || !orgId) return
    setError(null)
    if (!isHttpsUrl(url.trim())) {
      setError(t("masters.spareVideos.httpsOnly"))
      return
    }
    try {
      await createMut.mutateAsync({ org_id: orgId, spare_id: spareId, url: url.trim(), title: title.trim() || null, language })
      setUrl("")
      setTitle("")
      setLanguage(null)
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        if (!next) onClose()
      }}
    >
      <DialogContent className="max-w-lg">
        <DialogTitle className="flex items-center gap-1.5">
          <Video className="size-4 text-accent" />
          {t("masters.spareVideos.title")} — {spareName}
        </DialogTitle>

        {isLoading ? (
          <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
        ) : (
          <div className="space-y-2.5">
            {(videos ?? []).length === 0 ? (
              <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("masters.productMedia.videosEmpty")}</p>
            ) : (
              <ul className="space-y-1">
                {(videos ?? []).map((v) => (
                  <li key={v.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
                    <a href={v.url} target="_blank" rel="noreferrer" className="flex items-center gap-1.5 truncate text-sm text-text hover:underline">
                      <Video className="size-3.5 shrink-0 text-text-muted" />
                      {v.title || v.url}
                    </a>
                    <div className="flex shrink-0 items-center gap-1">
                      <VideoLanguageSelect
                        value={v.language}
                        disabled={updateMut.isPending}
                        className="h-7 rounded-lg border border-border bg-surface px-1.5 text-xs text-text outline-none"
                        onChange={(next) => updateMut.mutate({ id: v.id, patch: { language: next } })}
                      />
                      <button
                        type="button"
                        onClick={() => updateMut.mutate({ id: v.id, patch: { is_active: !v.is_active } })}
                        className={`rounded-full px-2 py-0.5 text-xs font-semibold ${v.is_active ? "bg-success/10 text-success" : "bg-danger/10 text-danger"}`}
                      >
                        {v.is_active ? t("masters.active") : t("masters.inactive")}
                      </button>
                      <Button size="icon-xs" variant="ghost" onClick={() => deleteMut.mutate(v.id)} title={t("masters.delete")}>
                        <Trash2 className="size-3.5 text-danger" />
                      </Button>
                    </div>
                  </li>
                ))}
              </ul>
            )}
            <div className="flex items-center gap-1.5">
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder={t("masters.productMedia.videoTitlePlaceholder")}
                className="h-9 w-2/5 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              />
              <VideoLanguageSelect value={language} onChange={setLanguage} />
              <input
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                placeholder={t("masters.productMedia.videoUrlPlaceholder")}
                className="h-9 flex-1 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              />
              <Button size="sm" className="gap-1" disabled={!url.trim() || createMut.isPending} onClick={handleAdd}>
                {createMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
                {t("masters.productMedia.addVideo")}
              </Button>
            </div>
            {error ? <p className="text-xs text-danger">{error}</p> : null}
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
