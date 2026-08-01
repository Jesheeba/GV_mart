import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Pencil, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { appointmentSlotsHooks } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { AppointmentSlotRow } from "@/services/masters"

// Supabase/PostgREST rejections aren't `instanceof Error` — same helper as
// EntityCrudTable/ProductComplaintsPanel, duplicated for the same reason
// (small, not worth exporting a shared utility for).
function extractErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message
  if (typeof e === "object" && e !== null && "message" in e && typeof (e as { message: unknown }).message === "string") {
    return (e as { message: string }).message
  }
  return String(e)
}

type FormState = { name: string; startTime: string; endTime: string; isActive: boolean; maxBookingsPerSlot: string }
const EMPTY_FORM: FormState = { name: "", startTime: "09:00", endTime: "12:00", isActive: true, maxBookingsPerSlot: "" }

/**
 * Customer Dashboard Booking Audit (2026-07-31) Tasks 2/3 — dedicated
 * Appointment Slot configuration, independent of technician working hours.
 * Bespoke (not EntityCrudTable) because start/end are time-of-day and
 * active is a boolean toggle, which the shared CrudFieldDef union doesn't
 * model — same "entities with real structure get bespoke UI" precedent as
 * Products/AMC Plans/Settings itself.
 */
export function AppointmentSlotsCard() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: rows, isLoading, isError, refetch } = appointmentSlotsHooks.useList(orgId)
  const createMut = appointmentSlotsHooks.useCreate()
  const updateMut = appointmentSlotsHooks.useUpdate()
  const deleteMut = appointmentSlotsHooks.useDelete()

  const [formOpen, setFormOpen] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [form, setForm] = useState<FormState>(EMPTY_FORM)
  const [formError, setFormError] = useState<string | null>(null)
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null)

  function openAdd() {
    setEditingId(null)
    setForm(EMPTY_FORM)
    setFormError(null)
    setFormOpen(true)
  }
  function openEdit(row: AppointmentSlotRow) {
    setEditingId(row.id)
    setForm({
      name: row.name,
      startTime: row.start_time.slice(0, 5),
      endTime: row.end_time.slice(0, 5),
      isActive: row.is_active,
      maxBookingsPerSlot: row.max_bookings_per_slot != null ? String(row.max_bookings_per_slot) : "",
    })
    setFormError(null)
    setFormOpen(true)
  }
  function closeForm() {
    setFormOpen(false)
    setEditingId(null)
    setFormError(null)
  }

  async function submit() {
    setFormError(null)
    if (!form.name.trim()) {
      setFormError(t("settings.appointmentSlots.nameRequired"))
      return
    }
    if (form.startTime >= form.endTime) {
      setFormError(t("settings.appointmentSlots.timeInvalid"))
      return
    }
    const patch = {
      name: form.name.trim(),
      start_time: form.startTime,
      end_time: form.endTime,
      is_active: form.isActive,
      max_bookings_per_slot: form.maxBookingsPerSlot.trim() ? Number(form.maxBookingsPerSlot) : null,
    }
    try {
      if (editingId) await updateMut.mutateAsync({ id: editingId, patch })
      else await createMut.mutateAsync({ org_id: orgId!, ...patch })
      closeForm()
    } catch (e) {
      setFormError(extractErrorMessage(e))
    }
  }

  async function handleDelete(id: string) {
    setFormError(null)
    try {
      await deleteMut.mutateAsync(id)
      setConfirmingDeleteId(null)
    } catch (e) {
      setFormError(extractErrorMessage(e))
    }
  }

  const isMutating = createMut.isPending || updateMut.isPending

  return (
    <Card className="gap-4">
      <div className="flex items-center justify-between px-1">
        <h3 className="text-sm font-semibold text-text">{t("settings.appointmentSlots.title")}</h3>
        {!formOpen ? (
          <Button size="sm" variant="outline" onClick={openAdd}>
            <Plus className="size-3.5" />
            {t("settings.appointmentSlots.add")}
          </Button>
        ) : null}
      </div>
      <p className="px-1 text-xs text-text-muted">{t("settings.appointmentSlots.hint")}</p>

      {formError ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{formError}</p> : null}

      {formOpen ? (
        <div className="grid grid-cols-2 gap-3 rounded-xl border border-border p-3.5 sm:grid-cols-4">
          <div className="space-y-1 sm:col-span-2">
            <Label>{t("settings.appointmentSlots.name")}</Label>
            <Input
              value={form.name}
              onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
              placeholder={t("settings.appointmentSlots.namePlaceholder")}
            />
          </div>
          <div className="space-y-1">
            <Label>{t("settings.appointmentSlots.startTime")}</Label>
            <input
              type="time"
              value={form.startTime}
              onChange={(e) => setForm((f) => ({ ...f, startTime: e.target.value }))}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            />
          </div>
          <div className="space-y-1">
            <Label>{t("settings.appointmentSlots.endTime")}</Label>
            <input
              type="time"
              value={form.endTime}
              onChange={(e) => setForm((f) => ({ ...f, endTime: e.target.value }))}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            />
          </div>
          <div className="space-y-1">
            <Label>{t("settings.appointmentSlots.maxBookings")}</Label>
            <Input
              type="number"
              min={1}
              step="1"
              value={form.maxBookingsPerSlot}
              onChange={(e) => setForm((f) => ({ ...f, maxBookingsPerSlot: e.target.value }))}
              placeholder={t("settings.appointmentSlots.maxBookingsPlaceholder")}
            />
          </div>
          <label className="flex items-center gap-2 self-end pb-2 text-sm text-text">
            <input
              type="checkbox"
              checked={form.isActive}
              onChange={(e) => setForm((f) => ({ ...f, isActive: e.target.checked }))}
              className="size-4 rounded border-border"
            />
            {t("masters.active")}
          </label>
          <div className="col-span-full flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={closeForm}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" onClick={submit} disabled={isMutating}>
              {isMutating ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
            </Button>
          </div>
        </div>
      ) : null}

      {isError ? (
        <div className="flex flex-col items-center gap-2 py-6 text-center">
          <p className="text-sm text-text-muted">{t("masters.loadFailed")}</p>
          <Button variant="outline" size="sm" onClick={() => refetch()}>
            {t("common.retry")}
          </Button>
        </div>
      ) : isLoading ? (
        <p className="py-4 text-center text-sm text-text-muted">{t("common.loading")}</p>
      ) : (rows ?? []).length === 0 ? (
        <p className="px-1 text-sm text-text-muted">{t("settings.appointmentSlots.empty")}</p>
      ) : (
        <ul className="space-y-1.5">
          {(rows ?? []).map((s) => (
            <li key={s.id} className="flex items-center justify-between gap-2 rounded-xl border border-border px-3.5 py-2.5">
              <div>
                <div className="flex items-center gap-1.5">
                  <span className="text-sm font-medium text-text">{s.name}</span>
                  <span
                    className={`rounded-full px-1.5 py-0.5 text-[10px] font-semibold ${
                      s.is_active ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
                    }`}
                  >
                    {s.is_active ? t("masters.active") : t("masters.inactive")}
                  </span>
                </div>
                <p className="text-xs text-text-muted">
                  {s.start_time.slice(0, 5)}–{s.end_time.slice(0, 5)}
                  {s.max_bookings_per_slot != null
                    ? ` · ${t("settings.appointmentSlots.maxBookingsValue", { count: s.max_bookings_per_slot })}`
                    : ""}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                {confirmingDeleteId === s.id ? (
                  <span className="flex items-center gap-1.5 text-xs">
                    <button
                      type="button"
                      className="text-danger hover:underline disabled:opacity-50"
                      disabled={deleteMut.isPending}
                      onClick={() => handleDelete(s.id)}
                    >
                      {deleteMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("masters.confirmDelete")}
                    </button>
                    <button type="button" className="text-text-muted hover:underline" onClick={() => setConfirmingDeleteId(null)}>
                      {t("common.cancel")}
                    </button>
                  </span>
                ) : (
                  <>
                    <Button size="icon-xs" variant="ghost" title={t("masters.edit")} onClick={() => openEdit(s)}>
                      <Pencil className="size-3.5" />
                    </Button>
                    <Button size="icon-xs" variant="ghost" title={t("masters.delete")} onClick={() => setConfirmingDeleteId(s.id)}>
                      <Trash2 className="size-3.5 text-danger" />
                    </Button>
                  </>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
