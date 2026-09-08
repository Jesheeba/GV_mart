// Standalone PDF-generation piece of the supplier document-quote-request
// work (compliance investigation, 2026-09-03) — deliberately NOT wired into
// open_monthly_quote_requests, sendMessage(), or whatsapp_outbox yet. Wasi
// has no document/media send today, and a document-header WhatsApp template
// needs manual submission via Wasi's own dashboard UI (their Hub API has no
// template-submission endpoint) plus Meta approval, timeline unknown,
// before any send code can consume the URL this produces. This module only
// builds the PDF bytes; generate-quote-pdf/index.ts wraps it with the real
// data lookup + storage upload.
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1"

export type QuoteRequestPdfInput = {
  orgName: string
  orgAddress: string | null
  orgPhone: string | null
  orgGstNo: string | null
  itemName: string
  orderQty: number
  requestedAt: string // ISO
  requestRef: string // short id shown on the document, e.g. the request id's first 8 chars, uppercased
}

const PAGE_WIDTH = 595.28 // A4 at 72dpi
const PAGE_HEIGHT = 841.89
const MARGIN = 50

export async function buildQuoteRequestPdf(input: QuoteRequestPdfInput): Promise<Uint8Array> {
  const doc = await PDFDocument.create()
  const page = doc.addPage([PAGE_WIDTH, PAGE_HEIGHT])
  const font = await doc.embedFont(StandardFonts.Helvetica)
  const bold = await doc.embedFont(StandardFonts.HelveticaBold)
  const black = rgb(0, 0, 0)
  const gray = rgb(0.4, 0.4, 0.4)

  let y = PAGE_HEIGHT - MARGIN

  // ── Letterhead ──────────────────────────────────────────────────────────
  page.drawText(input.orgName, { x: MARGIN, y, size: 18, font: bold, color: black })
  y -= 20
  if (input.orgAddress) {
    page.drawText(input.orgAddress, { x: MARGIN, y, size: 10, font, color: gray })
    y -= 14
  }
  const contactBits = [input.orgPhone ? `Phone: ${input.orgPhone}` : null, input.orgGstNo ? `GSTIN: ${input.orgGstNo}` : null].filter(Boolean)
  if (contactBits.length) {
    page.drawText(contactBits.join("   |   "), { x: MARGIN, y, size: 10, font, color: gray })
    y -= 14
  }
  y -= 6
  page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_WIDTH - MARGIN, y }, thickness: 1, color: black })
  y -= 28

  // ── Title + reference ───────────────────────────────────────────────────
  page.drawText("PURCHASE QUOTE REQUEST", { x: MARGIN, y, size: 14, font: bold, color: black })
  const refLabel = `Ref: ${input.requestRef}    Date: ${new Date(input.requestedAt).toLocaleDateString("en-IN")}`
  const refWidth = font.widthOfTextAtSize(refLabel, 10)
  page.drawText(refLabel, { x: PAGE_WIDTH - MARGIN - refWidth, y: y + 2, size: 10, font, color: gray })
  y -= 30

  page.drawText("Kindly quote your best price per unit for the item below and reply on WhatsApp.", { x: MARGIN, y, size: 10, font, color: black })
  y -= 30

  // ── Item table (single row — one item per request; price column left
  // blank for the supplier to fill in by hand or quote back over WhatsApp).
  // Item names longer than the column width are not wrapped — acceptable
  // for this first pass, revisit if real item names run long in practice. ──
  const colX = { sno: MARGIN, item: MARGIN + 40, qty: MARGIN + 320, price: MARGIN + 390 }
  const tableRight = PAGE_WIDTH - MARGIN
  const rowHeight = 26
  const headerRowTop = y
  const bodyRowTop = headerRowTop - rowHeight
  const tableBottom = bodyRowTop - rowHeight

  function drawRow(rowTop: number, cells: { sno: string; item: string; qty: string; price: string }, rowFont = font) {
    const textY = rowTop - 17
    page.drawText(cells.sno, { x: colX.sno + 4, y: textY, size: 10, font: rowFont, color: black })
    page.drawText(cells.item, { x: colX.item + 4, y: textY, size: 10, font: rowFont, color: black })
    page.drawText(cells.qty, { x: colX.qty + 4, y: textY, size: 10, font: rowFont, color: black })
    page.drawText(cells.price, { x: colX.price + 4, y: textY, size: 10, font: rowFont, color: black })
  }

  drawRow(headerRowTop, { sno: "S.No", item: "Item", qty: "Qty", price: "Price/Unit (Rs.)" }, bold)
  drawRow(bodyRowTop, { sno: "1", item: input.itemName, qty: String(input.orderQty), price: "" })

  page.drawRectangle({ x: MARGIN, y: tableBottom, width: tableRight - MARGIN, height: headerRowTop - tableBottom, borderColor: black, borderWidth: 1 })
  for (const x of [colX.item, colX.qty, colX.price]) {
    page.drawLine({ start: { x, y: tableBottom }, end: { x, y: headerRowTop }, thickness: 0.5, color: black })
  }
  page.drawLine({ start: { x: MARGIN, y: bodyRowTop }, end: { x: tableRight, y: bodyRowTop }, thickness: 0.5, color: black })

  y = tableBottom - 24
  page.drawText("Please reply with your quoted price directly on WhatsApp.", { x: MARGIN, y, size: 9, font, color: gray })

  return doc.save()
}
