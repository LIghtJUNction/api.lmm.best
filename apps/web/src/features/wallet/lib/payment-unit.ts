/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import { usesDedicatedPaymentPricing } from '@/lib/payment-pricing'

import type { PaymentMethod } from '../types'

const SETTLEMENT_UNIT_PATTERN = /^[A-Za-z0-9._-]{1,16}$/
const POSITIVE_DECIMAL_PATTERN = /^[0-9]+(?:\.[0-9]+)?$/

export type PaymentSettlementUnit = {
  label: string
  unitPrice: number
}

/**
 * Normalize a server-owned per-method payment multiplier. Missing or invalid
 * metadata keeps legacy payment methods at the neutral multiplier of 1.
 */
export function getPaymentTopupRatio(paymentMethod?: PaymentMethod): number {
  if (usesDedicatedPaymentPricing(paymentMethod?.type)) return 1

  const rawRatio = paymentMethod?.topup_ratio
  if (typeof rawRatio === 'string') {
    if (!POSITIVE_DECIMAL_PATTERN.test(rawRatio)) return 1
    const parsedRatio = Number(rawRatio)
    return Number.isFinite(parsedRatio) && parsedRatio > 0 ? parsedRatio : 1
  }

  return typeof rawRatio === 'number' &&
    Number.isFinite(rawRatio) &&
    rawRatio > 0
    ? rawRatio
    : 1
}

/**
 * Normalize optional gateway pricing metadata from a server-owned payment
 * method. Invalid values deliberately fall back to the standard currency UI.
 */
export function getPaymentSettlementUnit(
  paymentMethod?: PaymentMethod
): PaymentSettlementUnit | null {
  if (usesDedicatedPaymentPricing(paymentMethod?.type)) return null

  const label = paymentMethod?.settlement_unit
  if (!label || !SETTLEMENT_UNIT_PATTERN.test(label)) return null

  const rawPrice = paymentMethod?.unit_price
  if (typeof rawPrice === 'string') {
    if (!POSITIVE_DECIMAL_PATTERN.test(rawPrice)) return null
    const parsedPrice = Number(rawPrice)
    if (!Number.isFinite(parsedPrice) || parsedPrice <= 0) return null
    return { label, unitPrice: parsedPrice }
  }

  if (
    typeof rawPrice !== 'number' ||
    !Number.isFinite(rawPrice) ||
    rawPrice <= 0
  ) {
    return null
  }
  return { label, unitPrice: rawPrice }
}

/**
 * Formats the configured rate itself, not a calculated monetary amount. String
 * rates are kept byte-for-byte so small valid decimals never render as zero.
 */
export function formatPaymentSettlementRate(
  paymentMethod?: PaymentMethod
): string | null {
  const settlementUnit = getPaymentSettlementUnit(paymentMethod)
  if (!settlementUnit) return null

  const rawPrice = paymentMethod?.unit_price
  const price =
    typeof rawPrice === 'string'
      ? rawPrice
      : new Intl.NumberFormat('en-US', {
          maximumFractionDigits: 20,
          useGrouping: false,
        }).format(settlementUnit.unitPrice)

  return `${price} ${settlementUnit.label} / USD`
}

export function formatSettlementAmount(amount: number, unit: string): string {
  const maximumFractionDigits = Math.abs(amount) >= 1 ? 2 : 4
  const formatted = new Intl.NumberFormat(undefined, {
    maximumFractionDigits,
  }).format(amount)
  return `${formatted} ${unit}`
}
