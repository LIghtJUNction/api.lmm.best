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
  claimOnboardingAssistantPrompt,
  claimPendingReviewAssistantPrompt,
} from './pending-review-assistant'

function memoryStorage() {
  const values = new Map<string, string>()
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
  }
}

describe('pending review assistant prompt', () => {
  test('opens once when a fresh L0 user enters onboarding', () => {
    const storage = memoryStorage()
    assert.equal(claimOnboardingAssistantPrompt(900, 0, storage), true)
    assert.equal(claimOnboardingAssistantPrompt(900, 0, storage), false)
  })

  test('opens once for each valid review request', () => {
    const storage = memoryStorage()
    assert.equal(claimPendingReviewAssistantPrompt(901, 801, storage), true)
    assert.equal(claimPendingReviewAssistantPrompt(901, 801, storage), false)
    assert.equal(claimPendingReviewAssistantPrompt(901, 802, storage), true)
  })

  test('falls back to an in-memory claim when storage is blocked', () => {
    const blockedStorage = {
      getItem: () => {
        throw new Error('blocked')
      },
      setItem: () => {
        throw new Error('blocked')
      },
    }
    assert.equal(
      claimPendingReviewAssistantPrompt(902, 803, blockedStorage),
      true
    )
    assert.equal(
      claimPendingReviewAssistantPrompt(902, 803, blockedStorage),
      false
    )
  })

  test('rejects incomplete identities', () => {
    const storage = memoryStorage()
    assert.equal(claimOnboardingAssistantPrompt(0, 0, storage), false)
    assert.equal(claimOnboardingAssistantPrompt(903, -1, storage), false)
    assert.equal(claimPendingReviewAssistantPrompt(0, 804, storage), false)
    assert.equal(claimPendingReviewAssistantPrompt(903, -1, storage), false)
  })
})
