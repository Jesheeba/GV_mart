import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, Briefcase, MapPin, MessageCircle, Package, Phone, Pencil, ReceiptText, Target, Wrench } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useCustomer } from "@/hooks/useCustomers"
import { useProfile } from "@/hooks/useProfile"
import { FamilyMembersPanel } from "./FamilyMembersPanel"

function initials(name: string) {
  const parts = name.trim().split(/\s+/)
  return ((parts[0]?.[0] ?? "") + (parts[1]?.[0] ?? "")).toUpperCase()
}

function EmptyTab({ icon: Icon, label }: { icon: typeof Package; label: string }) {
  return (
    <div className="flex flex-col items-center gap-2 py-10 text-center">
      <span className="flex size-10 items-center justify-center rounded-full bg-surface-alt text-text-muted">
        <Icon className="size-5" />
      </span>
      <p className="text-sm text-text-muted">{label}</p>
    </div>
  )
}

export function CustomerDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const { data: customer, isLoading, isError, refetch } = useCustomer(id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !customer) {
    return <FullPageError message={t("customers.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const primaryAddress = customer.addresses.find((a) => a.is_primary) ?? customer.addresses[0]
  const waNumber = customer.mobile.replace(/\D/g, "")

  return (
    <div className="space-y-4 pt-2">
      <button
        type="button"
        onClick={() => navigate("/admin/customers")}
        className="flex items-center gap-1.5 text-sm font-medium text-text-muted hover:text-text"
      >
        <ArrowLeft className="size-4" />
        {t("customers.detail.backToList")}
      </button>

      <Card className="gap-4">
        <div className="flex flex-wrap items-start justify-between gap-4 px-1">
          <div className="flex items-start gap-4">
            <span className="flex size-14 shrink-0 items-center justify-center rounded-full bg-ink text-lg font-semibold text-white">
              {initials(customer.name)}
            </span>
            <div>
              <h1 className="text-xl font-bold text-text">{customer.name}</h1>
              <p className="text-sm text-text-muted">{customer.mobile}</p>
              {customer.profession ? (
                <p className="mt-1 flex items-center gap-1.5 text-sm text-text-muted">
                  <Briefcase className="size-3.5" />
                  {customer.profession}
                </p>
              ) : null}
              {primaryAddress ? (
                <p className="mt-1 flex items-start gap-1.5 text-sm text-text-muted">
                  <MapPin className="mt-0.5 size-3.5 shrink-0" />
                  <span>
                    {[primaryAddress.door_no, primaryAddress.street_cross, primaryAddress.area, primaryAddress.pincode]
                      .filter(Boolean)
                      .join(", ")}
                    <span className="ml-2 rounded-full bg-surface-alt px-2 py-0.5 text-xs capitalize">
                      {t(`customers.form.${primaryAddress.address_type}`)}
                    </span>
                  </span>
                </p>
              ) : (
                <p className="mt-1 text-sm text-text-muted">{t("customers.detail.noAddress")}</p>
              )}
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="icon"
              title={t("customers.detail.call")}
              nativeButton={false}
              render={<a href={`tel:${customer.mobile}`} />}
            >
              <Phone className="size-4" />
            </Button>
            <Button
              variant="outline"
              size="icon"
              title={t("customers.detail.whatsapp")}
              nativeButton={false}
              render={<a href={`https://wa.me/91${waNumber}`} target="_blank" rel="noreferrer" />}
            >
              <MessageCircle className="size-4" />
            </Button>
            <Button onClick={() => navigate(`/admin/customers/${customer.id}/edit`)}>
              <Pencil className="size-4" />
              {t("customers.detail.actions.edit")}
            </Button>
          </div>
        </div>

        <div className="flex flex-wrap gap-2 border-t border-border px-1 pt-3">
          <Button variant="outline" disabled title={t("customers.detail.actions.comingSoonReason")}>
            {t("customers.detail.actions.newSale")}
          </Button>
          <Button variant="outline" disabled title={t("customers.detail.actions.comingSoonReason")}>
            {t("customers.detail.actions.newTicket")}
          </Button>
          <Button variant="outline" disabled title={t("customers.detail.actions.comingSoonReason")}>
            {t("customers.detail.actions.sellAmc")}
          </Button>
        </div>
      </Card>

      <FamilyMembersPanel orgId={profile?.org_id} customerId={customer.id} members={customer.customer_members} />

      <Card size="default">
        <Tabs defaultValue="products">
          <TabsList>
            <TabsTrigger value="products">{t("customers.detail.tabs.products")}</TabsTrigger>
            <TabsTrigger value="service">{t("customers.detail.tabs.service")}</TabsTrigger>
            <TabsTrigger value="invoices">{t("customers.detail.tabs.invoices")}</TabsTrigger>
            <TabsTrigger value="leads">{t("customers.detail.tabs.leads")}</TabsTrigger>
          </TabsList>
          <TabsContent value="products">
            <EmptyTab icon={Package} label={t("customers.detail.emptyTabs.products")} />
          </TabsContent>
          <TabsContent value="service">
            <EmptyTab icon={Wrench} label={t("customers.detail.emptyTabs.service")} />
          </TabsContent>
          <TabsContent value="invoices">
            <EmptyTab icon={ReceiptText} label={t("customers.detail.emptyTabs.invoices")} />
          </TabsContent>
          <TabsContent value="leads">
            <EmptyTab icon={Target} label={t("customers.detail.emptyTabs.leads")} />
          </TabsContent>
        </Tabs>
      </Card>
    </div>
  )
}
