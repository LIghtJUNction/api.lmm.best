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
  formatPaymentSettlementRate,
  formatSettlementAmount,
  getPaymentTopupRatio,
  getPaymentSettlementUnit,
} from './payment-unit'

describe('payment settlement units', () => {
  test('normalizes a Linux.do LDC price per credited USD', () => {
    assert.deepEqual(
      getPaymentSettlementUnit({
        name: 'LINUX DO Credit',
        settlement_unit: 'LDC',
        type: 'epay',
        unit_price: '10',
      }),
      { label: 'LDC', unitPrice: 10 }
    )
    assert.equal(formatSettlementAmount(0.14, 'LDC'), '0.14 LDC')
  })

  test('does not render a custom currency for incomplete or invalid metadata', () => {
    assert.equal(
      getPaymentSettlementUnit({ name: 'Linux', type: 'epay' }),
      null
    )
    assert.equal(
      getPaymentSettlementUnit({
        name: 'Linux',
        settlement_unit: 'LDC',
        type: 'epay',
        unit_price: 'not-a-number',
      }),
      null
    )
    assert.equal(
      getPaymentSettlementUnit({
        name: 'Linux',
        settlement_unit: 'LDC',
        type: 'epay',
        unit_price: '1e3',
      }),
      null
    )
  })

  test('rejects unsafe settlement-unit metadata from the server', () => {
    for (const settlementUnit of [
      ' LDC ',
      'LD C',
      'LDC\u0000',
      'LDC!',
      'A'.repeat(17),
    ]) {
      assert.equal(
        getPaymentSettlementUnit({
          name: 'Linux',
          settlement_unit: settlementUnit,
          type: 'epay',
          unit_price: '10',
        }),
        null
      )
    }
  })

  test('rejects whitespace around a server-provided gateway price', () => {
    assert.equal(
      getPaymentSettlementUnit({
        name: 'Linux',
        settlement_unit: 'LDC',
        type: 'epay',
        unit_price: ' 10 ',
      }),
      null
    )
  })

  test('ignores generic settlement metadata on dedicated payment flows', () => {
    for (const type of ['stripe', 'waffo', 'waffo_pancake']) {
      const method = {
        name: type,
        settlement_unit: 'LDC',
        type,
        unit_price: '10',
      }

      assert.equal(getPaymentSettlementUnit(method), null)
      assert.equal(formatPaymentSettlementRate(method), null)
      assert.equal(getPaymentTopupRatio({ ...method, topup_ratio: '0.5' }), 1)
    }
  })

  test('preserves exact configured decimal rates in the wallet label', () => {
    assert.equal(
      formatPaymentSettlementRate({
        name: 'Tiny-rate gateway',
        settlement_unit: 'TOKEN',
        type: 'epay',
        unit_price: '0.000000000001',
      }),
      '0.000000000001 TOKEN / USD'
    )
    assert.equal(
      formatPaymentSettlementRate({
        name: 'Precise gateway',
        settlement_unit: 'TOKEN',
        type: 'custom-provider-method',
        unit_price: '1.2345',
      }),
      '1.2345 TOKEN / USD'
    )
  })

  test('normalizes a per-method top-up multiplier with a backward-compatible default', () => {
    assert.equal(
      getPaymentTopupRatio({
        name: 'LINUX DO Credit',
        topup_ratio: '0.5',
        type: 'epay',
      }),
      0.5
    )
    assert.equal(
      getPaymentTopupRatio({ name: 'Legacy method', type: 'alipay' }),
      1
    )

    for (const topupRatio of ['0', '-1', '1e2', ' 2 ', 'NaN']) {
      assert.equal(
        getPaymentTopupRatio({
          name: 'Invalid method',
          topup_ratio: topupRatio,
          type: 'epay',
        }),
        1
      )
    }
  })
})
