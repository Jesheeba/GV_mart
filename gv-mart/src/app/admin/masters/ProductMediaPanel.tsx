import { useState } from "react"
import { useTranslation } from "react-i18next"
import { ArrowDown, ArrowUp, FileText, Image as ImageIcon, Loader2, Plus, Star, Trash2, Video } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import {
  useCreateProductVideo,
  useDeleteProductDocument,
  useDeleteProductImage,
  useDeleteProductVideo,
  useProductDocuments,
  useProductImages,
  useProductVideos,
  useSetPrimaryProductImage,
  useUpdateProductImage,
  useUpdateProductVideo,
  useUploadProductDocument,
  useUploadProductImage,
} from "@/hooks/useMasters"
import { productDocumentPublicUrl, productImagePublicUrl } from "@/services/productMedia"
import type { Tables, TablesInsert } from "@/types/database"

// Supabase/PostgREST rejections aren't `instanceof Error` — same helper as
// EntityCrudTable/ProductSparesPanel, duplicated for the same reason (small,
// not worth exporting a shared utility for).
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

const DOC_TYPES: TablesInsert<"product_documents">["doc_type"][] = ["brochure", "manual", "warranty_card", "other"]
const MAX_FILE_BYTES = 5 * 1024 * 1024

/**
 * Product Enquiry rebuild (2026-08-04), Phase 1 — admin-side product media
 * manager (images/documents/videos). Opened from a row action in
 * Masters > Products (ProductsTab.tsx), same per-product-Dialog-panel shape
 * as ProductSparesPanel.tsx.
 */
export function ProductMediaPanel({
  orgId,
  productId,
  productName,
  onClose,
}: {
  orgId: string | undefined
  productId: string
  productName: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  return (
    <Dialog
      open
      onOpenChange={(next) => {
        if (!next) onClose()
      }}
    >
      <DialogContent className="max-w-lg">
        <DialogTitle className="flex items-center gap-1.5">
          <ImageIcon className="size-4 text-accent" />
          {t("masters.productMedia.title")} — {productName}
        </DialogTitle>

        <Tabs defaultValue="images">
          <TabsList>
            <TabsTrigger value="images">{t("masters.productMedia.imagesTab")}</TabsTrigger>
            <TabsTrigger value="documents">{t("masters.productMedia.documentsTab")}</TabsTrigger>
            <TabsTrigger value="videos">{t("masters.productMedia.videosTab")}</TabsTrigger>
          </TabsList>

          <TabsContent value="images">
            <ImagesTab orgId={orgId} productId={productId} />
          </TabsContent>
          <TabsContent value="documents">
            <DocumentsTab orgId={orgId} productId={productId} />
          </TabsContent>
          <TabsContent value="videos">
            <VideosTab orgId={orgId} productId={productId} />
          </TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
  )
}

function ImagesTab({ orgId, productId }: { orgId: string | undefined; productId: string }) {
  const { t } = useTranslation()
  const { data: images, isLoading } = useProductImages(productId)
  const uploadMut = useUploadProductImage(productId)
  const updateMut = useUpdateProductImage(productId)
  const deleteMut = useDeleteProductImage(productId)
  const primaryMut = useSetPrimaryProductImage(productId)
  const [error, setError] = useState<string | null>(null)

  const rows = (images ?? []) as Tables<"product_images">[]

  async function handleFiles(files: FileList | null) {
    if (!files || !orgId) return
    setError(null)
    for (const file of Array.from(files)) {
      if (file.size > MAX_FILE_BYTES) {
        setError(t("masters.productMedia.fileTooLarge"))
        continue
      }
      try {
        await uploadMut.mutateAsync({ orgId, file })
      } catch (e) {
        setError(extractErrorMessage(e))
      }
    }
  }

  async function move(row: Tables<"product_images">, direction: -1 | 1) {
    const sorted = [...rows].sort((a, b) => a.sort_order - b.sort_order)
    const idx = sorted.findIndex((r) => r.id === row.id)
    const swapWith = sorted[idx + direction]
    if (!swapWith) return
    setError(null)
    try {
      await Promise.all([
        updateMut.mutateAsync({ id: row.id, patch: { sort_order: swapWith.sort_order } }),
        updateMut.mutateAsync({ id: swapWith.id, patch: { sort_order: row.sort_order } }),
      ])
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  if (isLoading) return <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>

  return (
    <div className="space-y-2.5">
      {rows.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("masters.productMedia.imagesEmpty")}</p>
      ) : (
        <ul className="grid grid-cols-3 gap-2">
          {[...rows]
            .sort((a, b) => a.sort_order - b.sort_order)
            .map((r) => (
              <li key={r.id} className="relative rounded-xl border border-border p-1.5">
                <img src={productImagePublicUrl(r.storage_path)} alt="" className="aspect-square w-full rounded-lg object-cover" />
                {r.is_primary ? (
                  <span className="absolute top-1 left-1 rounded-full bg-accent px-1.5 py-0.5 text-[10px] font-semibold text-white">
                    {t("masters.productMedia.primary")}
                  </span>
                ) : null}
                <div className="mt-1 flex items-center justify-between">
                  <div className="flex items-center gap-0.5">
                    <Button size="icon-xs" variant="ghost" onClick={() => move(r, -1)} title={t("masters.productMedia.moveUp")}>
                      <ArrowUp className="size-3" />
                    </Button>
                    <Button size="icon-xs" variant="ghost" onClick={() => move(r, 1)} title={t("masters.productMedia.moveDown")}>
                      <ArrowDown className="size-3" />
                    </Button>
                  </div>
                  <div className="flex items-center gap-0.5">
                    {!r.is_primary ? (
                      <Button size="icon-xs" variant="ghost" onClick={() => primaryMut.mutate(r.id)} title={t("masters.productMedia.setPrimary")}>
                        <Star className="size-3" />
                      </Button>
                    ) : null}
                    <Button size="icon-xs" variant="ghost" onClick={() => deleteMut.mutate(r.id)} title={t("masters.delete")}>
                      <Trash2 className="size-3 text-danger" />
                    </Button>
                  </div>
                </div>
              </li>
            ))}
        </ul>
      )}
      <label className="flex cursor-pointer items-center justify-center gap-1.5 rounded-xl border border-dashed border-border px-3 py-2.5 text-sm text-text-muted hover:bg-surface-alt/60">
        {uploadMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
        {t("masters.productMedia.uploadImage")}
        <input type="file" accept="image/jpeg,image/png,image/webp" multiple className="hidden" onChange={(e) => handleFiles(e.target.files)} />
      </label>
      {error ? <p className="text-xs text-danger">{error}</p> : null}
    </div>
  )
}

function DocumentsTab({ orgId, productId }: { orgId: string | undefined; productId: string }) {
  const { t } = useTranslation()
  const { data: documents, isLoading } = useProductDocuments(productId)
  const uploadMut = useUploadProductDocument(productId)
  const deleteMut = useDeleteProductDocument(productId)
  const [label, setLabel] = useState("")
  const [docType, setDocType] = useState<TablesInsert<"product_documents">["doc_type"]>("brochure")
  const [pendingFile, setPendingFile] = useState<File | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function handleUpload() {
    if (!pendingFile || !orgId || !label.trim()) return
    setError(null)
    try {
      await uploadMut.mutateAsync({ orgId, file: pendingFile, label: label.trim(), docType })
      setLabel("")
      setPendingFile(null)
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  if (isLoading) return <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>

  return (
    <div className="space-y-2.5">
      {(documents ?? []).length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-3 py-2.5 text-xs text-text-muted">{t("masters.productMedia.documentsEmpty")}</p>
      ) : (
        <ul className="space-y-1">
          {(documents ?? []).map((d) => (
            <li key={d.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3 py-2">
              <a href={productDocumentPublicUrl(d.storage_path)} target="_blank" rel="noreferrer" className="flex items-center gap-1.5 text-sm text-text hover:underline">
                <FileText className="size-3.5 text-text-muted" />
                {d.label}
                <span className="text-xs text-text-muted">({t(`masters.productMedia.docType.${d.doc_type}`)})</span>
              </a>
              <Button size="icon-xs" variant="ghost" onClick={() => deleteMut.mutate(d.id)} title={t("masters.delete")}>
                <Trash2 className="size-3.5 text-danger" />
              </Button>
            </li>
          ))}
        </ul>
      )}

      <div className="space-y-1.5 rounded-xl border border-border p-3">
        <Label>{t("masters.productMedia.docLabel")}</Label>
        <input
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          placeholder={t("masters.productMedia.docLabelPlaceholder")}
          className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        />
        <select
          value={docType}
          onChange={(e) => setDocType(e.target.value as TablesInsert<"product_documents">["doc_type"])}
          className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
        >
          {DOC_TYPES.map((dt) => (
            <option key={dt} value={dt}>
              {t(`masters.productMedia.docType.${dt}`)}
            </option>
          ))}
        </select>
        <input type="file" accept="application/pdf" onChange={(e) => setPendingFile(e.target.files?.[0] ?? null)} className="text-xs text-text-muted" />
        <Button size="sm" className="w-full gap-1" disabled={!pendingFile || !label.trim() || uploadMut.isPending} onClick={handleUpload}>
          {uploadMut.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Plus className="size-3.5" />}
          {t("masters.productMedia.uploadDocument")}
        </Button>
        {error ? <p className="text-xs text-danger">{error}</p> : null}
      </div>
    </div>
  )
}

function VideosTab({ orgId, productId }: { orgId: string | undefined; productId: string }) {
  const { t } = useTranslation()
  const { data: videos, isLoading } = useProductVideos(productId)
  const createMut = useCreateProductVideo(productId)
  const updateMut = useUpdateProductVideo(productId)
  const deleteMut = useDeleteProductVideo(productId)
  const [url, setUrl] = useState("")
  const [title, setTitle] = useState("")
  const [error, setError] = useState<string | null>(null)

  async function handleAdd() {
    if (!url.trim() || !orgId) return
    setError(null)
    try {
      await createMut.mutateAsync({ org_id: orgId, product_id: productId, url: url.trim(), title: title.trim() || null })
      setUrl("")
      setTitle("")
    } catch (e) {
      setError(extractErrorMessage(e))
    }
  }

  if (isLoading) return <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>

  return (
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
  )
}
