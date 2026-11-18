import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, CheckCheck, SendHorizonal, User } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useProfile } from "@/hooks/useProfile"
import { useSimulateInboundWhatsapp, useWhatsappTranscript } from "@/hooks/useAutomation"
import { formatTime } from "@/lib/formatDate"
import type { WhatsappOutboxRow } from "@/services/automation"
import { cn } from "@/lib/utils"

/** ADM-23's "/api/whatsapp/webhook" has no real HTTP route to host in this
 * Vite SPA — this panel calls the same `simulate_inbound_whatsapp` RPC a
 * real Edge Function webhook would call, so admins can verify flow matching
 * end-to-end without live WhatsApp credentials. Styled as a WhatsApp-style
 * chat window (not a form + log table) so what admins see here reads the
 * same way the real conversation will look to the customer. */

function Bubble({ row }: { row: WhatsappOutboxRow }) {
  const outbound = row.direction !== "inbound"
  const body = (row.payload as { body?: string } | null)?.body ?? row.template
  return (
    <div className={cn("flex", outbound ? "justify-end" : "justify-start")}>
      <div
        className={cn(
          "relative max-w-[75%] rounded-lg px-2.5 py-1.5 text-sm leading-snug shadow-sm",
          outbound ? "rounded-tr-none bg-[#d9fdd3] text-[#111b21] dark:bg-[#005c4b] dark:text-[#e9edef]" : "rounded-tl-none bg-white text-[#111b21] dark:bg-[#202c33] dark:text-[#e9edef]"
        )}
      >
        <p className="whitespace-pre-wrap break-words pr-10">{body}</p>
        <span className="float-right mt-1 ml-1.5 flex translate-y-1 items-center gap-0.5 text-[10px] text-[#667781] dark:text-[#8696a0]">
          {formatTime(row.created_at)}
          {outbound ? <CheckCheck className="size-3.5 text-[#53bdeb]" /> : null}
        </span>
      </div>
    </div>
  )
}

export function InboundTestTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [phone, setPhone] = useState("9840000000")
  const [body, setBody] = useState("")
  const transcript = useWhatsappTranscript(orgId, phone || undefined)
  const simulate = useSimulateInboundWhatsapp()
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [transcript.data])

  async function send() {
    const text = body.trim()
    if (!text || !orgId) return
    setBody("")
    await simulate.mutateAsync({ orgId, fromMobile: phone, body: text })
  }

  return (
    <div className="flex h-[640px] flex-col overflow-hidden rounded-xl border border-border">
      {/* header */}
      <div className="flex items-center gap-3 bg-[#008069] px-4 py-2.5 text-white dark:bg-[#202c33]">
        <div className="flex size-9 items-center justify-center rounded-full bg-white/20">
          <User className="size-4.5" />
        </div>
        <div className="min-w-0 flex-1">
          <Input
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            placeholder={t("automation.inbox.fromMobile")}
            className="h-7 w-44 border-none bg-transparent px-0 text-sm font-semibold text-white placeholder:text-white/60 focus-visible:ring-0"
          />
          <p className="text-[11px] text-white/70">{t("automation.inbox.testHint")}</p>
        </div>
      </div>

      {/* chat */}
      <div ref={scrollRef} className="flex-1 space-y-1.5 overflow-y-auto bg-[#efeae2] px-4 py-3 dark:bg-[#0b141a]">
        {transcript.isLoading ? (
          <p className="py-10 text-center text-sm text-[#667781] dark:text-[#8696a0]">…</p>
        ) : (transcript.data ?? []).length === 0 ? (
          <p className="py-10 text-center text-sm text-[#667781] dark:text-[#8696a0]">{t("automation.inbox.empty")}</p>
        ) : (
          (transcript.data ?? []).map((row) => <Bubble key={row.id} row={row} />)
        )}
      </div>

      {/* composer */}
      <div className="flex items-center gap-2 bg-[#f0f2f5] px-3 py-2 dark:bg-[#202c33]">
        <Input
          value={body}
          onChange={(e) => setBody(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              send()
            }
          }}
          placeholder={t("automation.inbox.bodyPlaceholder")}
          className="h-10 flex-1 rounded-full border-none bg-white px-4 shadow-sm dark:bg-[#2a3942]"
        />
        <Button size="icon" className="size-10 shrink-0 rounded-full bg-[#008069] hover:bg-[#008069]/90" disabled={simulate.isPending || !body.trim()} onClick={send}>
          {simulate.isPending ? <Check className="size-4 animate-pulse" /> : <SendHorizonal className="size-4" />}
        </Button>
      </div>
      {simulate.error ? <p className="bg-danger/10 px-3 py-1.5 text-xs text-danger">{(simulate.error as Error).message}</p> : null}
    </div>
  )
}
