import { billBreakdown } from "@/lib/sale-calc"
import type { Enums } from "@/types/database"

export type CartProductLine = {
  productId: string
  name: string
  brandName: string
  modelName: string
  category: Enums<"brand_category">
  price: number
  qty: number
  warranty: boolean
  warrantyMonths: number
  installation: boolean
}

export type CartSpareLine = {
  spareId: string
  name: string
  price: number
  qty: number
}

export type CartAmc = {
  productId: string
  productName: string
  planId: string
  planName: string
  price: number
}

export type SaleCartState = {
  productLines: CartProductLine[]
  spareLines: CartSpareLine[]
  amc: CartAmc | null
}

export function cartIsEmpty(cart: SaleCartState) {
  return cart.productLines.length === 0 && cart.spareLines.length === 0 && !cart.amc
}

export function productSubtotal(cart: SaleCartState) {
  return cart.productLines.reduce((sum, l) => sum + l.qty * l.price, 0)
}
export function spareSubtotal(cart: SaleCartState) {
  return cart.spareLines.reduce((sum, l) => sum + l.qty * l.price, 0)
}
export function amcSubtotal(cart: SaleCartState) {
  return cart.amc ? cart.amc.price : 0
}
export function combinedSubtotal(cart: SaleCartState) {
  return productSubtotal(cart) + spareSubtotal(cart) + amcSubtotal(cart)
}

/** Same per-invoice-type breakdown SaleSummaryPanel shows as "Amount payable" — shared so the payment step's amount-collected default can never drift from what the summary panel displays. Client-side preview only, create_sale recomputes authoritatively. */
export function payableTotal(cart: SaleCartState, discountPercent: number, gstRatePercent: number, redeemAmount: number) {
  const spareTotal = spareSubtotal(cart) > 0 ? billBreakdown(spareSubtotal(cart), discountPercent, gstRatePercent).total : 0
  const productTotal = productSubtotal(cart) > 0 ? billBreakdown(productSubtotal(cart), discountPercent, gstRatePercent).total : 0
  const amcTotal = amcSubtotal(cart) > 0 ? billBreakdown(amcSubtotal(cart), discountPercent, gstRatePercent).total : 0
  const grandTotal = spareTotal + productTotal + amcTotal
  return Math.max(0, grandTotal - Math.min(redeemAmount, grandTotal))
}
