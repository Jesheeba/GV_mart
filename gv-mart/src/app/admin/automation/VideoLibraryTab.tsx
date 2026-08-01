import { useTranslation } from "react-i18next"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { useCreateVideoLibraryEntry, useDeleteVideoLibraryEntry, useUpdateVideoLibraryEntry, useVideoLibrary } from "@/hooks/useAutomation"
import { useProfile } from "@/hooks/useProfile"
import type { VideoLibraryRow } from "@/services/automation"

const TOPICS = ["online", "price", "quality", "customization", "water_premium", "budget"] as const

export function VideoLibraryTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rows, isLoading, isError, refetch } = useVideoLibrary(orgId)
  const createMut = useCreateVideoLibraryEntry()
  const updateMut = useUpdateVideoLibraryEntry()
  const deleteMut = useDeleteVideoLibraryEntry()

  const fields: CrudFieldDef[] = [
    { key: "topic", label: t("automation.videos.topic"), type: "select", options: TOPICS.map((v) => ({ value: v, label: t(`leads.enquiryType.${v}`) })) },
    { key: "url", label: t("automation.videos.url"), type: "url", required: true },
  ]

  return (
    <EntityCrudTable<VideoLibraryRow>
      fields={fields}
      rows={rows ?? []}
      getId={(r) => r.id}
      loading={isLoading}
      error={isError ? t("automation.loadFailed") : null}
      onRetry={() => refetch()}
      isMutating={createMut.isPending || updateMut.isPending}
      addLabel={t("automation.videos.add")}
      emptyMessage={t("automation.videos.empty")}
      toFormValues={(r) => ({ topic: r.topic, url: r.url })}
      columns={[
        { key: "topic", header: t("automation.videos.topic"), render: (r) => t(`leads.enquiryType.${r.topic}`) },
        { key: "url", header: t("automation.videos.url"), render: (r) => r.url },
      ]}
      onCreate={(v) => createMut.mutateAsync({ org_id: orgId!, topic: v.topic as VideoLibraryRow["topic"], url: v.url })}
      onUpdate={(id, v) => updateMut.mutateAsync({ id, patch: { topic: v.topic as VideoLibraryRow["topic"], url: v.url } })}
      onDelete={(id) => deleteMut.mutateAsync(id)}
    />
  )
}
