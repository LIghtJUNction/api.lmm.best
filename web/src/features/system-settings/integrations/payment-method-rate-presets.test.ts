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
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import {
  formatPositiveDecimal,
  getPaymentMethodRatePresets,
} from './payment-method-rate-presets'

describe('payment method rate presets', () => {
  test('formats ordinary global prices as strict decimal strings', () => {
    assert.equal(formatPositiveDecimal(7.3), '7.3')
    assert.equal(formatPositiveDecimal(1), '1')
    assert.equal(formatPositiveDecimal(0.14), '0.14')
  })

  test('returns the global Price and reciprocal presets', () => {
    assert.deepEqual(getPaymentMethodRatePresets(7.3), {
      currentGlobalPrice: '7.3',
      reciprocalGlobalPrice: '0.13698630137',
    })
    assert.deepEqual(getPaymentMethodRatePresets(1), {
      currentGlobalPrice: '1',
      reciprocalGlobalPrice: '1',
    })
    assert.deepEqual(getPaymentMethodRatePresets(0.14), {
      currentGlobalPrice: '0.14',
      reciprocalGlobalPrice: '7.142857142857',
    })
  })

  test('rejects invalid or unrepresentably small input rates', () => {
    for (const value of [
      0,
      -1,
      Number.NaN,
      Number.POSITIVE_INFINITY,
      Number.MIN_VALUE,
    ]) {
      assert.equal(formatPositiveDecimal(value), null)
      assert.equal(getPaymentMethodRatePresets(value), null)
    }
  })

  test('never emits exponent notation and limits fractional precision', () => {
    for (const value of [1e-7, 1e21, 1 / 3]) {
      const formatted = formatPositiveDecimal(value)
      assert.ok(formatted)
      assert.doesNotMatch(formatted, /[eE]/)
      assert.match(formatted, /^[0-9]+(?:\.[0-9]+)?$/)
      const fraction = formatted.split('.')[1] || ''
      assert.ok(fraction.length <= 12)
    }
    assert.equal(formatPositiveDecimal(1 / 3), '0.333333333333')
  })
})
