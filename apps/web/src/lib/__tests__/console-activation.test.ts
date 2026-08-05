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

import type { AuthUser } from '@/stores/auth-store'

import {
  isConsoleActivated,
  isContributorRoute,
  isRestrictedPublicRoute,
} from '../console-activation'

function user(role: number, consoleActivatedAt?: number): AuthUser {
  return {
    id: 7,
    username: 'contributor',
    role,
    permissions: { console_activated_at: consoleActivatedAt },
  }
}

describe('console activation boundary', () => {
  test('keeps explicit new accounts restricted until first credential activation', () => {
    assert.equal(isConsoleActivated(user(1, 0)), false)
    assert.equal(isConsoleActivated(user(1, 1720000000)), true)
  })

  test('keeps administrators and legacy responses activated', () => {
    assert.equal(isConsoleActivated(user(10, 0)), true)
    assert.equal(isConsoleActivated(user(1)), true)
  })

  test('allows only contributor, wallet, and profile routes before activation', () => {
    assert.equal(isContributorRoute('/workspace'), true)
    assert.equal(isContributorRoute('/challenges/42'), true)
    assert.equal(isContributorRoute('/wallet'), true)
    assert.equal(isContributorRoute('/profile/security'), true)
    assert.equal(isContributorRoute('/models'), false)
    assert.equal(isContributorRoute('/open-source-bounties'), false)
  })

  test('hides legacy public discovery surfaces before activation', () => {
    assert.equal(isRestrictedPublicRoute('/pricing'), true)
    assert.equal(isRestrictedPublicRoute('/pricing/model-1'), true)
    assert.equal(isRestrictedPublicRoute('/rankings'), true)
    assert.equal(isRestrictedPublicRoute('/about'), true)
    assert.equal(isRestrictedPublicRoute('/challenges/42'), false)
    assert.equal(isRestrictedPublicRoute('/privacy-policy'), false)
    assert.equal(isRestrictedPublicRoute('/sign-in'), false)
  })
})
