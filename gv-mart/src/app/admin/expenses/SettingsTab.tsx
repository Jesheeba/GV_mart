import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useProfile } from "@/hooks/useProfile"
import { setOwnBikeAllowanceBase } from "@/services/monthlyExpenses"
import { supabase } from "@/lib/supabase"

/** Monthly Expenses spec §1.6/§3.6 — the own-bike allowance base amount,
 *  editable by master only (narrower than this page's operation_admin
 *  access, so the control itself checks the role rather than gating the
 *  whole route). */
export function SettingsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const qc = useQueryClient()
  const settings = useQuery({
    queryKey: ["settings", "ownBikeAllowanceBase", profile?.org_id],
    queryFn: async () => {
      const { data, error } = await supabase.from("settings").select("own_bike_allowance_base").eq("org_id", profile!.org_id).single()
      if (error) throw error
      return data as unknown as { own_bike_allowance_base: number }
    },
    enabled: !!profile?.org_id,
  })
  const [value, setValue] = useState("")
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (settings.data) setValue(String(settings.data.own_bike_allowance_base))
  }, [settings.data])

  if (profile && profile.role !== "master") {
    return <p className="text-sm text-text-muted">{t("expenses.settings.masterOnly")}</p>
  }

  async function save() {
    if (!profile?.org_id) return
    setSaving(true)
    setError(null)
    try {
      await setOwnBikeAllowanceBase(profile.org_id, Number(value))
      qc.invalidateQueries({ queryKey: ["settings"] })
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Card className="gap-2.5">
      <p className="text-sm font-semibold text-text">{t("expenses.settings.ownBikeAllowanceBase")}</p>
      <p className="text-xs text-text-muted">{t("expenses.settings.hint")}</p>
      <div className="space-y-1">
        <Label htmlFor="bike-base">{t("expenses.settings.amount")}</Label>
        <Input id="bike-base" type="number" min={0} step="50" value={value} onChange={(e) => setValue(e.target.value)} />
      </div>
      {error ? <p className="text-xs text-danger">{error}</p> : null}
      <Button type="button" size="sm" disabled={saving} onClick={save}>
        {t("expenses.settings.save")}
      </Button>
    </Card>
  )
}
