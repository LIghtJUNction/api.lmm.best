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
import type { PaymentMethod } from '../types'

const SETTLEMENT_UNIT_PATTERN = /^[A-Za-z0-9._-]{1,16}$/
const POSITIVE_DECIMAL_PATTERN = /^[0-9]+(?:\.[0-9]+)?$/

export type PaymentSettlementUnit = {
  label: string
  unitPrice: number
}

/**
 * Normalize optional gateway pricing metadata from a server-owned payment
 * method. Invalid values deliberately fall back to the standard currency UI.
 */
export function getPaymentSettlementUnit(
  paymentMethod?: PaymentMethod
): PaymentSettlementUnit | null {
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

export function formatSettlementAmount(amount: number, unit: string): string {
  const maximumFractionDigits = Math.abs(amount) >= 1 ? 2 : 4
  const formatted = new Intl.NumberFormat(undefined, {
    maximumFractionDigits,
  }).format(amount)
  return `${formatted} ${unit}`
}
