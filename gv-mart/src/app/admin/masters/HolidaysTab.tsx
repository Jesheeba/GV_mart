import { useTranslation } from "react-i18next"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { EntityCrudTable, type CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { useProfile } from "@/hooks/useProfile"
import { createHoliday, deleteHoliday, listHolidays, updateHoliday, type OrgHolidayRow } from "@/services/technicianTable"

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

/** Masters > Holidays: days that are not working days for the technician table's absent-day count. Empty = no holidays. */
export function HolidaysTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const qc = useQueryClient()
  const list = useQuery({ queryKey: ["org_holidays", orgId], queryFn: () => listHolidays(orgId!), enabled: !!orgId })
  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ["org_holidays"] })
    void qc.invalidateQueries({ queryKey: ["technicianTable"] })
  }
  const create = useMutation({ mutationFn: createHoliday, onSuccess: refresh })
  const update = useMutation({ mutationFn: ({ id, patch }: { id: string; patch: { holiday_date?: string; name?: string } }) => updateHoliday(id, patch), onSuccess: refresh })
  const remove = useMutation({ mutationFn: deleteHoliday, onSuccess: refresh })

  const fields: CrudFieldDef[] = [
    { key: "holiday_date", label: t("masters.holidays.date"), type: "text", required: true, placeholder: "YYYY-MM-DD" },
    { key: "name", label: t("masters.holidays.name"), type: "text", required: true },
  ]
  const check = (v: Record<string, string>) => {
    if (!DATE_RE.test((v.holiday_date ?? "").trim())) throw new Error(t("masters.holidays.badDate"))
  }

  return (
    <div className="space-y-3">
      <div className="px-1">
        <h3 className="text-sm font-semibold text-text">{t("masters.holidays.title")}</h3>
        <p className="text-xs text-text-muted">{t("masters.holidays.hint")}</p>
      </div>
      <EntityCrudTable<OrgHolidayRow>
        fields={fields}
        rows={list.data ?? []}
        getId={(r) => r.id}
        loading={list.isLoading}
        error={list.isError ? t("masters.loadFailed") : null}
        onRetry={() => list.refetch()}
        isMutating={create.isPending || update.isPending}
        addLabel={t("masters.holidays.add")}
        emptyMessage={t("masters.holidays.empty")}
        toFormValues={(r) => ({ holiday_date: r.holiday_date, name: r.name })}
        columns={[
          { key: "date", header: t("masters.holidays.date"), render: (r) => <span className="gv-tnum font-medium text-text">{r.holiday_date}</span> },
          { key: "name", header: t("masters.holidays.name"), render: (r) => r.name },
        ]}
        onCreate={async (v) => {
          check(v)
          return create.mutateAsync({ org_id: orgId!, holiday_date: v.holiday_date.trim(), name: v.name.trim() })
        }}
        onUpdate={async (id, v) => {
          check(v)
          return update.mutateAsync({ id, patch: { holiday_date: v.holiday_date.trim(), name: v.name.trim() } })
        }}
        onDelete={(id) => remove.mutateAsync(id)}
      />
    </div>
  )
}
