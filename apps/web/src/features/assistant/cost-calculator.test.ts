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

import type { PricingModel } from '@/features/pricing/types'

import { calculateAssistantTextCost } from './cost-calculator'

const model: PricingModel = {
  id: 1,
  model_name: 'example-model',
  quota_type: 0,
  model_ratio: 1.5,
  completion_ratio: 2,
  enable_groups: ['default'],
}

describe('assistant cost calculator', () => {
  test('uses the same ratio contract as pricing', () => {
    const estimate = calculateAssistantTextCost(model, 0.8, 500_000, 250_000)
    assert.ok(estimate)
    assert.ok(Math.abs(estimate.inputRatePerMillionUSD - 2.4) < 1e-12)
    assert.ok(Math.abs(estimate.outputRatePerMillionUSD - 4.8) < 1e-12)
    assert.ok(Math.abs(estimate.totalUSD - 2.4) < 1e-12)
  })

  test('rejects unsupported or invalid estimates', () => {
    assert.equal(
      calculateAssistantTextCost(
        { ...model, billing_mode: 'tiered_expr' },
        1,
        100,
        100
      ),
      null
    )
    assert.equal(calculateAssistantTextCost(model, 1, -1, 100), null)
  })
})
