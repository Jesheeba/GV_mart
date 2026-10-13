// STOP / STOP ALL / START recognition for inbound WhatsApp messages (automation Phase 3 / Stage A, item S3).
//
//   STOP      -> promotions, feedback, review requests and renewal reminders stop; job updates and invoices continue
//   STOP ALL  -> nothing is sent
//   START     -> resubscribe. Only honoured when the number currently has an opt-out on record, so a customer typing
//                "start" to the bot is never hijacked.
//
// START with NO opt-out on record: the exact words START, SUBSCRIBE and RESUME get ONE friendly "already receiving" reply
// (English only until the Tamil line is reviewed). Any other text, including sentences containing "start", and the
// other restart words (unstop, start again, Tamil) go to the bot untouched.
// Whole-message match only (after trimming punctuation/emoji and folding case): "please stop the leak" is NOT an opt-out.
// The record is written through the service-role RPC wa_record_opt_out(); this module never sends outside the 24 h window
// (the confirmation is a reply to a message the customer has just sent, so it is inside the window).
//
// Pure helpers are exported for tests; handleOptOutKeyword takes the Supabase client and sender as arguments so it can be
// unit-tested without the Deno runtime. No Edge Function is deployed by this change.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export type OptOutAction = "stop" | "stop_all" | "start"

// folded forms (see foldKeyword)
const STOP = ["stop", "unsubscribe", "நிறுத்து", "நிறுத்துங்கள்", "நிறுத்தவும்", "நிறுத்துங்கள"]
const STOP_ALL = [
  "stop all", "stopall", "stop all messages", "stop everything", "unsubscribe all",
  "அனைத்தையும் நிறுத்து", "எல்லாவற்றையும் நிறுத்து", "அனைத்தும் நிறுத்து",
]
const START = ["start", "subscribe", "resume", "unstop", "start again", "தொடங்கு", "தொடங்குங்கள்"]

/** lower-case, drop everything except letters, digits and spaces (Tamil letters and combining marks are kept) */
export function foldKeyword(text: string): string {
  return text
    .normalize("NFC")
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
}

export function detectOptOutKeyword(text: string | null | undefined): OptOutAction | null {
  if (!text) return null
  const folded = foldKeyword(text)
  if (!folded || folded.length > 40) return null
  if (STOP_ALL.includes(folded)) return "stop_all"
  if (STOP.includes(folded)) return "stop"
  if (START.includes(folded)) return "start"
  return null
}

const TAMIL = /[஀-௿]/

export type OptOutLang = "en" | "ta"

export function optOutLanguage(text: string): OptOutLang {
  return TAMIL.test(text) ? "ta" : "en"
}

// Tamil strings are DRAFT: need review by a Tamil speaker (docs/tamil-review-wasi-templates.md).
export function optOutReply(action: OptOutAction, lang: OptOutLang): string {
  const en: Record<OptOutAction, string> = {
    stop:
      "You will no longer receive feedback requests, renewal reminders or promotional messages from GV Mart. Updates about your service requests and invoices will continue. Reply STOP ALL to stop every message, or START to subscribe again.",
    stop_all: "You will not receive any more messages from GV Mart. Reply START to subscribe again.",
    start: "You are subscribed again. Thank you.",
  }
  const ta: Record<OptOutAction, string> = {
    stop:
      "GV Mart-இலிருந்து கருத்து கோரிக்கைகள், புதுப்பிப்பு நினைவூட்டல்கள் மற்றும் விளம்பர செய்திகள் இனி வராது. உங்கள் சேவை கோரிக்கைகள் மற்றும் இன்வாய்ஸ் தகவல்கள் தொடர்ந்து வரும். அனைத்து செய்திகளையும் நிறுத்த STOP ALL என்றும், மீண்டும் பெற START என்றும் பதிலளிக்கவும்.",
    stop_all: "GV Mart-இலிருந்து இனி எந்த செய்தியும் வராது. மீண்டும் பெற START என்று பதிலளிக்கவும்.",
    start: "நீங்கள் மீண்டும் சேர்க்கப்பட்டுள்ளீர்கள். நன்றி.",
  }
  return (lang === "ta" ? ta : en)[action]
}

/** The only words that get the "already subscribed" reply when there is nothing to resubscribe (owner decision 2026-10-13). */
const PLAIN_START = ["start", "subscribe", "resume"]

export function isPlainStartKeyword(text: string | null | undefined): boolean {
  if (!text) return false
  return PLAIN_START.includes(foldKeyword(text))
}

/** Sent when a number that is not opted out writes START / SUBSCRIBE / RESUME. English only until the Tamil review. */
export const ALREADY_SUBSCRIBED_REPLY_EN =
  "You are already receiving messages from GV Mart. Reply STOP to stop reminders and offers, or STOP ALL to stop everything. Type MENU to see how we can help."

/**
 * DRAFT, NOT REVIEWED, NOT SENT: needs review by a Tamil speaker. Kept here so the review has something to check; no code path
 * returns it. Tamil-preference customers receive the English line until this is signed off.
 */
export const ALREADY_SUBSCRIBED_REPLY_TA_DRAFT_NOT_REVIEWED =
  "நீங்கள் ஏற்கனவே GV Mart செய்திகளைப் பெறுகிறீர்கள். நினைவூட்டல்கள் மற்றும் விளம்பரங்களை நிறுத்த STOP, அனைத்தையும் நிறுத்த STOP ALL என்று பதிலளிக்கவும். உதவிக்கு MENU என்று தட்டச்சு செய்யவும்."

/** The reply for an already-subscribed number. The language argument is accepted for the future; today it is always English. */
export function alreadySubscribedReply(_lang: OptOutLang): string {
  return ALREADY_SUBSCRIBED_REPLY_EN
}

export type OptOutSend = (input: {
  orgId: string
  to: string
  customerId: string | null
  template: string
  body: string
}) => Promise<unknown>

const tenDigits = (phone: string) => phone.replace(/\D/g, "").slice(-10)

/**
 * Returns true when the message was an opt-out keyword and was handled (record written, one confirmation sent): the caller
 * must stop processing the message. Returns false for anything else, including START from a number with no opt-out.
 */
export async function handleOptOutKeyword(
  admin: SupabaseClient,
  orgId: string,
  phone: string,
  text: string | null | undefined,
  send: OptOutSend,
): Promise<boolean> {
  const action = detectOptOutKeyword(text)
  if (!action) return false
  const key = tenDigits(phone)
  if (key.length !== 10) return false

  if (action === "start") {
    const { data } = await admin
      .from("customer_comm_prefs")
      .select("opt_out_non_job, opt_out_all")
      .eq("org_id", orgId)
      .eq("mobile_key", key)
      .maybeSingle()
    const row = data as { opt_out_non_job: boolean; opt_out_all: boolean } | null
    if (!row || (!row.opt_out_non_job && !row.opt_out_all)) {
      // Nothing to resubscribe. The plain words get one friendly reply; anything else goes to the bot untouched.
      if (!isPlainStartKeyword(text)) return false
      await send({
        orgId,
        to: key,
        customerId: null,
        template: "wa.opt_out.already_subscribed",
        body: alreadySubscribedReply(optOutLanguage(text ?? "")),
      })
      return true
    }
  }

  const { error } = await admin.rpc("wa_record_opt_out", { p_org: orgId, p_mobile: key, p_action: action, p_source: "whatsapp" })
  if (error) {
    console.error("wa-opt-out: wa_record_opt_out failed", error.code ?? "", error.message ?? "")
    return false // fall through to the normal bot rather than swallow the customer's message silently
  }

  await send({
    orgId,
    to: key,
    customerId: null,
    template: `wa.opt_out.${action}`,
    body: optOutReply(action, optOutLanguage(text ?? "")),
  })
  return true
}
