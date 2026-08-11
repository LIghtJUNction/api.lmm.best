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

import { isValidPaymentMethodData } from './payment-method-validation'

describe('payment method JSON validation', () => {
  test('accepts complete, Go-compatible settlement metadata', () => {
    assert.equal(
      isValidPaymentMethodData({
        name: 'LINUX DO Credit',
        settlement_unit: 'LDC',
        topup_ratio: '0.5',
        type: 'epay',
        unit_price: '10',
      }),
      true
    )
  })

  test('accepts provider-defined Epay types with channel pricing', () => {
    assert.equal(
      isValidPaymentMethodData({
        name: 'Provider custom method',
        settlement_unit: 'POINTS',
        type: 'provider_method_v2',
        unit_price: '2.75',
      }),
      true
    )
  })

  test('accepts unlock delay and unified audience filters', () => {
    assert.equal(
      isValidPaymentMethodData({
        name: 'LinuxDO card',
        type: 'stripe',
        unlock_after_days: '7',
        audience_mode: 'include',
        audience_match: 'any',
        audience_email_contains: 'linux.do',
        audience_oauth_provider: 'linuxdo',
        audience_linuxdo_score_min: '10000',
        audience_linuxdo_score_max: '20000.5',
      }),
      true
    )
  })

  test('rejects incomplete, unsafe, and non-decimal metadata', () => {
    const base = { name: 'LINUX DO Credit', type: 'epay' }
    for (const value of [
      { ...base, settlement_unit: 'LDC' },
      { ...base, unit_price: '10' },
      { ...base, settlement_unit: ' LDC', unit_price: '10' },
      { ...base, settlement_unit: 'LDC', unit_price: ' 10' },
      { ...base, settlement_unit: 'LDC', unit_price: '1e1' },
      { ...base, settlement_unit: 'LDC', unit_price: '0' },
      { ...base, settlement_unit: 'LDC', unit_price: 10 },
      { ...base, topup_ratio: '0' },
      { ...base, topup_ratio: '-1' },
      { ...base, topup_ratio: '1e2' },
      { ...base, topup_ratio: 2 },
      { ...base, unlock_after_days: '-1' },
      { ...base, unlock_after_days: '1.5' },
      { ...base, unlock_after_days: 7 },
      { ...base, audience_mode: 'include' },
      {
        ...base,
        audience_mode: 'include',
        audience_linuxdo_score_min: '20',
        audience_linuxdo_score_max: '10',
      },
      { ...base, audience_mode: 'sometimes' },
    ]) {
      assert.equal(isValidPaymentMethodData(value), false)
    }
  })
})
