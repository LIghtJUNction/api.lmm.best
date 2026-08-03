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
const MAXIMUM_FRACTION_DIGITS = 12
const POSITIVE_DECIMAL_PATTERN = /^[0-9]+(?:\.[0-9]+)?$/

export type PaymentMethodRatePresets = {
  currentGlobalPrice: string
  reciprocalGlobalPrice: string
}

/**
 * Converts a positive finite JavaScript number into the decimal-only format
 * accepted by payment-method pricing. The UI must never persist scientific
 * notation because the backend deliberately rejects it.
 */
export function formatPositiveDecimal(value: number): string | null {
  if (!Number.isFinite(value) || value <= 0) return null

  const formatted = new Intl.NumberFormat('en-US', {
    maximumFractionDigits: MAXIMUM_FRACTION_DIGITS,
    useGrouping: false,
  }).format(value)

  if (!POSITIVE_DECIMAL_PATTERN.test(formatted)) return null

  const normalized = formatted.replace(/(?:\.0+|(?:(\.\d*?[1-9]))0+)$/, '$1')
  const parsed = Number(normalized)
  if (!Number.isFinite(parsed) || parsed <= 0) return null

  return normalized
}

/**
 * Provides the two safe presets used by every payment channel: the configured
 * global Price and its reciprocal. An unusable rate makes both presets
 * unavailable so an invalid value cannot accidentally be saved to a gateway.
 */
export function getPaymentMethodRatePresets(
  globalPrice: number
): PaymentMethodRatePresets | null {
  const currentGlobalPrice = formatPositiveDecimal(globalPrice)
  const reciprocalGlobalPrice = formatPositiveDecimal(1 / globalPrice)

  if (!currentGlobalPrice || !reciprocalGlobalPrice) return null

  return { currentGlobalPrice, reciprocalGlobalPrice }
}
