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

import type { PlanRecord } from '@/features/subscriptions/types'

import {
  compareAssistantPlans,
  getAssistantTopupOffers,
} from './plan-recommender'

function plan(id: number, totalAmount: number): PlanRecord {
  return {
    plan: {
      id,
      title: `Plan ${id}`,
      price_amount: id * 10,
      currency: 'USD',
      duration_unit: 'month',
      duration_value: 1,
      quota_reset_period: 'monthly',
      enabled: true,
      sort_order: id,
      allow_balance_pay: true,
      allow_wallet_overflow: true,
      max_purchase_per_user: 0,
      total_amount: totalAmount,
    },
  }
}

describe('assistant plan recommender', () => {
  test('recommends the smallest included credit that covers the estimate', () => {
    const ranked = compareAssistantPlans(
      [plan(1, 5_000_000), plan(2, 15_000_000), plan(3, 30_000_000)],
      22,
      1_000_000
    )

    assert.equal(ranked[0]?.record.plan.id, 3)
    assert.equal(ranked[0]?.recommended, true)
    assert.equal(ranked[0]?.includedCreditUSD, 30)
    assert.equal(ranked[0]?.monthlyCreditUSD, 30)
  })

  test('falls back to the largest finite plan and keeps unlimited as coverage', () => {
    const finite = compareAssistantPlans(
      [plan(1, 5_000_000), plan(2, 15_000_000)],
      20,
      1_000_000
    )
    assert.equal(finite[0]?.record.plan.id, 2)

    const unlimited = compareAssistantPlans(
      [plan(1, 5_000_000), plan(3, 0)],
      20,
      1_000_000
    )
    assert.equal(unlimited[0]?.record.plan.id, 3)
    assert.equal(unlimited[0]?.includedCreditUSD, null)
  })

  test('normalizes daily and weekly reset quotas to monthly capacity', () => {
    const daily = plan(1, 1_000_000)
    daily.plan.quota_reset_period = 'daily'
    const weekly = plan(2, 7_000_000)
    weekly.plan.quota_reset_period = 'weekly'

    const ranked = compareAssistantPlans([daily, weekly], 29, 1_000_000)
    assert.equal(ranked[0]?.record.plan.id, 1)
    assert.equal(ranked[0]?.monthlyCreditUSD, 30)
    assert.equal(ranked[1]?.monthlyCreditUSD, 30)
  })

  test('normalizes and sorts real discount multipliers', () => {
    const offers = getAssistantTopupOffers({ 10: 1, 50: 0.9, 100: 0.8 })
    assert.deepEqual(
      offers.map(({ amount, multiplier }) => ({ amount, multiplier })),
      [
        { amount: 100, multiplier: 0.8 },
        { amount: 50, multiplier: 0.9 },
      ]
    )
    assert.ok(Math.abs((offers[0]?.savingsPercent ?? 0) - 20) < 1e-9)
    assert.ok(Math.abs((offers[1]?.savingsPercent ?? 0) - 10) < 1e-9)
    assert.deepEqual(getAssistantTopupOffers('{"100":0.8}'), [])
  })
})
