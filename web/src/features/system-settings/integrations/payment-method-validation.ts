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
import type { PaymentMethodData } from './payment-method-dialog'

const SETTLEMENT_UNIT_PATTERN = /^[A-Za-z0-9._-]{1,16}$/
const POSITIVE_DECIMAL_PATTERN = /^[0-9]+(?:\.[0-9]+)?$/

export function isValidPaymentMethodData(
  item: unknown
): item is PaymentMethodData {
  if (
    typeof item !== 'object' ||
    item === null ||
    !('name' in item) ||
    !('type' in item) ||
    typeof item.name !== 'string' ||
    typeof item.type !== 'string' ||
    ('icon' in item && typeof item.icon !== 'string') ||
    ('min_topup' in item && typeof item.min_topup !== 'string') ||
    ('topup_ratio' in item &&
      (typeof item.topup_ratio !== 'string' ||
        !POSITIVE_DECIMAL_PATTERN.test(item.topup_ratio) ||
        Number(item.topup_ratio) <= 0)) ||
    ('color' in item && typeof item.color !== 'string')
  ) {
    return false
  }

  const record = item as Record<string, unknown>
  const hasSettlementUnit = 'settlement_unit' in record
  const hasUnitPrice = 'unit_price' in record
  if (hasSettlementUnit !== hasUnitPrice) return false
  if (!hasSettlementUnit) return true

  const settlementUnit = record.settlement_unit
  const unitPrice = record.unit_price
  return (
    typeof settlementUnit === 'string' &&
    SETTLEMENT_UNIT_PATTERN.test(settlementUnit) &&
    typeof unitPrice === 'string' &&
    POSITIVE_DECIMAL_PATTERN.test(unitPrice) &&
    Number(unitPrice) > 0
  )
}
