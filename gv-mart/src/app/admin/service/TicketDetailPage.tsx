import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { Loader2, Pencil, UserCog } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import {
  useAssignTicketTechnician,
  useAutoAssignTicket,
  useCustomerAddresses,
  useTechnicians,
  useTicket,
  useUpdateTicketAddress,
} from "@/hooks/useService"
import { PriorityBadge, TicketTypeBadge } from "./TicketBadges"
import { SlaCountdown } from "./SlaCountdown"

function minutesBetween(start: string | null, end: string | null) {
  if (!start || !end) return null
  return Math.round((new Date(end).getTime() - new Date(start).getTime()) / 60_000)
}

export function TicketDetailPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: ticket, isLoading, isError, refetch } = useTicket(id)
  const { data: technicians } = useTechnicians(ticket?.org_id)
  const autoAssign = useAutoAssignTicket()
  const assign = useAssignTicketTechnician()
  const [pickerTechId, setPickerTechId] = useState("")

  const [editingAddress, setEditingAddress] = useState(false)
  const [addressPickerId, setAddressPickerId] = useState("")
  const addresses = useCustomerAddresses(editingAddress ? ticket?.customer_id : undefined)
  const updateAddress = useUpdateTicketAddress()

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !ticket) {
    return <FullPageError message={t("service.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const appointment = ticket.appointments[0]
  const visit = ticket.service_visits?.[0]
  const totalMinutes = visit ? minutesBetween(visit.timer_start, visit.timer_end) : null

  function startEditingAddress() {
    setAddressPickerId(ticket!.address_id ?? "")
    setEditingAddress(true)
  }
  function saveAddress() {
    updateAddress.mutate(
      { ticketId: ticket!.id, addressId: addressPickerId || null },
      { onSuccess: () => setEditingAddress(false), onError: () => toast.error(t("common.actionFailed")) }
    )
  }

  return (
    <div className="mx-auto max-w-3xl space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-text">#{ticket.id.slice(0, 8)}</h1>
          <p className="text-sm text-text-muted">{ticket.customers?.name} · {ticket.customers?.mobile}</p>
        </div>
        <Button variant="outline" onClick={() => navigate("/admin/service")}>
          {t("customers.form.back")}
        </Button>
      </div>

      <Card className="gap-3 px-5">
        <div className="flex flex-wrap items-center gap-2">
          <TicketTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
          <SlaCountdown slaDueAt={ticket.sla_due_at} status={ticket.status} />
          {ticket.invoice_id ? (
            <span className="text-xs text-text-muted">{t("service.detail.createdFromInvoice", { id: ticket.invoice_id.slice(0, 8) })}</span>
          ) : null}
        </div>
        <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
          <Field label={t("service.table.product")} value={[ticket.products?.name, ticket.brands?.name, ticket.models?.name].filter(Boolean).join(" · ") || "—"} />
          <Field label={t("service.newComplaint.nameOfComplaint")} value={ticket.name_of_complaint || "—"} />
          <Field label={t("service.newComplaint.natureOfComplaint")} value={ticket.nature_of_complaint || "—"} />
          <Field label={t("service.table.appointment")} value={appointment?.mode === "always" ? t("service.appointment.always") : appointment?.scheduled_at ? new Date(appointment.scheduled_at).toLocaleString() : "—"} />
          <Field label={t("service.detail.status")} value={t(`service.status.${ticket.status}`)} />
          {!editingAddress ? (
            <div>
              <div className="flex items-center gap-1.5 text-xs text-text-muted">
                {t("service.table.area")}
                <button type="button" onClick={startEditingAddress} className="text-accent" title={t("service.detail.editAddress")}>
                  <Pencil className="size-3" />
                </button>
              </div>
              <div className="text-text">{ticket.addresses?.area ?? "—"}</div>
            </div>
          ) : (
            <div className="space-y-1.5">
              <div className="text-xs text-text-muted">{t("service.table.area")}</div>
              <select
                value={addressPickerId}
                onChange={(e) => setAddressPickerId(e.target.value)}
                className="h-8 w-full rounded-xl border border-border bg-surface px-2.5 text-sm text-text outline-none"
              >
                <option value="">{t("service.newComplaint.addressNone")}</option>
                {(addresses.data ?? []).map((a) => (
                  <option key={a.id} value={a.id}>
                    {[a.door_no, a.area].filter(Boolean).join(", ") || a.id.slice(0, 8)}
                    {a.is_primary ? ` (${t("customers.detail.primary")})` : ""}
                  </option>
                ))}
              </select>
              <div className="flex gap-2">
                <Button size="xs" disabled={updateAddress.isPending} onClick={saveAddress}>
                  {updateAddress.isPending ? <Loader2 className="size-3 animate-spin" /> : t("common.save")}
                </Button>
                <Button size="xs" variant="ghost" onClick={() => setEditingAddress(false)}>
                  {t("common.cancel")}
                </Button>
              </div>
            </div>
          )}
        </div>
      </Card>

      <Card className="gap-3 px-5">
        <h2 className="text-sm font-semibold text-text">{t("service.detail.assignment")}</h2>
        {appointment?.technician_id ? (
          <p className="text-sm text-text">
            {t("service.detail.assignedTo", { name: appointment.technicians?.profiles?.full_name ?? "—" })}
          </p>
        ) : appointment ? (
          <div className="flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              onClick={() => autoAssign.mutate(ticket.id, { onError: () => toast.error(t("common.actionFailed")) })}
              disabled={autoAssign.isPending}
            >
              {autoAssign.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <UserCog className="size-3.5" />}
              {t("service.detail.autoAssign")}
            </Button>
            <select
              value={pickerTechId}
              onChange={(e) => setPickerTechId(e.target.value)}
              className="h-8 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("service.detail.pickTechnician")}</option>
              {(technicians ?? []).map((tc) => (
                <option key={tc.id} value={tc.id}>
                  {tc.full_name} {tc.is_on_duty ? "" : `(${t("service.detail.offDuty")})`}
                </option>
              ))}
            </select>
            <Button
              size="sm"
              variant="outline"
              disabled={!pickerTechId || assign.isPending}
              onClick={() =>
                appointment &&
                assign.mutate(
                  { appointmentId: appointment.id, technicianId: pickerTechId },
                  { onError: () => toast.error(t("common.actionFailed")) }
                )
              }
            >
              {t("service.detail.assignManually")}
            </Button>
          </div>
        ) : (
          <p className="text-sm text-text-muted">{t("service.detail.noAppointment")}</p>
        )}
        {autoAssign.data && !autoAssign.data.assigned ? (
          <p className="text-xs text-warning">{t(autoAssign.data.reason_key ?? "service.assign.noneAvailable")}</p>
        ) : null}
        {assign.data && !assign.data.assigned ? <p className="text-xs text-warning">{t(assign.data.reason_key ?? "service.assign.technicianBusy")}</p> : null}
      </Card>

      <Card className="gap-3 px-5">
        <h2 className="text-sm font-semibold text-text">{t("service.detail.jobReport")}</h2>
        {visit ? (
          <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <Field label={t("service.detail.startTime")} value={visit.timer_start ? new Date(visit.timer_start).toLocaleString() : "—"} />
            <Field label={t("service.detail.closeTime")} value={visit.timer_end ? new Date(visit.timer_end).toLocaleString() : "—"} />
            <Field label={t("service.detail.totalTime")} value={totalMinutes != null ? t("service.detail.minutes", { count: totalMinutes }) : "—"} />
            <Field label={t("service.detail.charge")} value={`₹${visit.service_charge.toLocaleString("en-IN")}`} />
          </div>
        ) : (
          <p className="text-sm text-text-muted">{t("service.detail.noVisitYet")}</p>
        )}
      </Card>
    </div>
  )
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs text-text-muted">{label}</div>
      <div className="text-text">{value}</div>
    </div>
  )
}
