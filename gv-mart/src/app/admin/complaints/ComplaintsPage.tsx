import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { AlertTriangle, Repeat } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useOverdueSlaTickets, useRepeatComplaintTickets } from "@/hooks/useSystemPages"
import type { OverdueTicket } from "@/services/systemPages"

function ComplaintsTable({
  rows,
  loading,
  error,
  onRetry,
  emptyMessage,
  onRowClick,
}: {
  rows: OverdueTicket[]
  loading: boolean
  error: boolean
  onRetry: () => void
  emptyMessage: string
  onRowClick: (id: string) => void
}) {
  const { t } = useTranslation()

  const columns: DataTableColumn<OverdueTicket>[] = [
    { key: "customer", header: t("complaints.table.customer"), render: (r) => r.customers?.name ?? "—" },
    { key: "mobile", header: t("complaints.table.mobile"), render: (r) => r.customers?.mobile ?? "—" },
    { key: "product", header: t("complaints.table.product"), render: (r) => r.products?.name ?? "—" },
    { key: "complaint", header: t("complaints.table.complaint"), render: (r) => r.name_of_complaint ?? "—" },
    { key: "priority", header: t("complaints.table.priority"), render: (r) => t(`service.priority.${r.priority}`) },
    { key: "status", header: t("complaints.table.status"), render: (r) => t(`service.status.${r.status}`) },
    {
      key: "slaDue",
      header: t("complaints.table.slaDue"),
      render: (r) => (r.sla_due_at ? new Date(r.sla_due_at).toLocaleString() : "—"),
    },
  ]

  return (
    <DataTable
      columns={columns}
      rows={rows}
      rowKey={(r) => r.id}
      loading={loading}
      error={error ? t("complaints.loadFailed") : null}
      onRetry={onRetry}
      emptyMessage={emptyMessage}
      onRowClick={(r) => onRowClick(r.id)}
    />
  )
}

export function ComplaintsPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()

  const overdue = useOverdueSlaTickets(profile?.org_id)
  const repeat = useRepeatComplaintTickets(profile?.org_id)

  function goToTicket(id: string) {
    navigate(`/admin/service/${id}`)
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-2xl font-bold text-text">{t("nav.complaints")}</h1>
        <p className="text-sm text-text-muted">{t("complaints.subtitle")}</p>
      </div>

      <Tabs defaultValue="overdue">
        <TabsList>
          <TabsTrigger value="overdue">
            <AlertTriangle className="size-3.5" />
            {t("complaints.tabs.overdueSla")} {overdue.data ? `(${overdue.data.length})` : ""}
          </TabsTrigger>
          <TabsTrigger value="repeat">
            <Repeat className="size-3.5" />
            {t("complaints.tabs.repeat")} {repeat.data ? `(${repeat.data.length})` : ""}
          </TabsTrigger>
        </TabsList>

        <Card size="default" className="mt-3">
          <TabsContent value="overdue">
            <ComplaintsTable
              rows={overdue.data ?? []}
              loading={overdue.isLoading}
              error={overdue.isError}
              onRetry={() => overdue.refetch()}
              emptyMessage={t("complaints.noOverdue")}
              onRowClick={goToTicket}
            />
          </TabsContent>
          <TabsContent value="repeat">
            <ComplaintsTable
              rows={repeat.data ?? []}
              loading={repeat.isLoading}
              error={repeat.isError}
              onRetry={() => repeat.refetch()}
              emptyMessage={t("complaints.noRepeat")}
              onRowClick={goToTicket}
            />
          </TabsContent>
        </Card>
      </Tabs>
    </div>
  )
}
