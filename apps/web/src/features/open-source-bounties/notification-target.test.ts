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

import { selectBountyNotificationChallenge } from './notification-target'
import type { BountyProjectDetail } from './types'

const detail = {
  project: { id: 41 },
  challenges: [
    { id: 71, project_id: 41 },
    { id: 72, project_id: 41 },
  ],
  ledger: [],
} as BountyProjectDetail

describe('bounty notification detail target', () => {
  test('selects the exact challenge within the requested project', () => {
    assert.equal(
      selectBountyNotificationChallenge(detail, {
        projectId: 41,
        challengeId: 72,
      })?.id,
      72
    )
  })

  test('rejects project and challenge identity mismatches', () => {
    assert.equal(
      selectBountyNotificationChallenge(detail, {
        projectId: 42,
        challengeId: 72,
      }),
      null
    )
    assert.equal(
      selectBountyNotificationChallenge(detail, {
        projectId: 41,
        challengeId: 99,
      }),
      null
    )
  })
})
