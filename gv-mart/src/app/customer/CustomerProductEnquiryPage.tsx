import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ArrowLeft } from "lucide-react"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { useMyCustomerId, useProductEnquiryTabs } from "@/hooks/useCustomerApp"
import { TAB_RENDERERS } from "./productEnquiry/moduleRegistry"

/**
 * Product Enquiry rebuild (2026-08-04) — rewritten to be config-driven.
 * Tabs (and, for the video_library tab, which topics show) now come from
 * admin-configured `product_enquiry_tabs` instead of a hardcoded array.
 * The original page body (topic chips + video grid + free-text quotation
 * form) is unchanged, just moved into VideoLibraryTabContent — this is a
 * hard regression gate: with the seed migration giving every org one
 * video_library tab carrying all 6 original topics in their original
 * order, this page must render bit-for-bit like the pre-rebuild version.
 */
export function CustomerProductEnquiryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: tabs, isLoading, isError, refetch } = useProductEnquiryTabs(orgId)
  const [activeTabId, setActiveTabId] = useState<string | null>(null)

  if (loadingId || isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.productEnquiry.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const sortedTabs = [...(tabs ?? [])].sort((a, b) => a.sort_order - b.sort_order)
  const currentTabId = activeTabId && sortedTabs.some((tab) => tab.id === activeTabId) ? activeTabId : sortedTabs[0]?.id

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
          <ArrowLeft className="size-4" />
          {t("customerApp.productEnquiry.close")}
        </button>
      </div>
      <h1 className="text-xl font-bold text-text">{t("customerApp.productEnquiry.title")}</h1>
      <p className="text-sm text-text-muted">{t("customerApp.productEnquiry.subtitle")}</p>

      {sortedTabs.length === 0 || !currentTabId ? (
        <p className="rounded-xl border border-dashed border-border px-3.5 py-6 text-center text-sm text-text-muted">{t("customerApp.productEnquiry.catalog.empty")}</p>
      ) : (
        <Tabs value={currentTabId} onValueChange={(v) => setActiveTabId(v)}>
          <TabsList>
            {sortedTabs.map((tab) => (
              <TabsTrigger key={tab.id} value={tab.id}>
                {tab.label}
              </TabsTrigger>
            ))}
          </TabsList>
          {sortedTabs.map((tab) => (
            <TabsContent key={tab.id} value={tab.id}>
              {TAB_RENDERERS[tab.tab_type]({ orgId, tab })}
            </TabsContent>
          ))}
        </Tabs>
      )}
    </div>
  )
}
