/*
Copyright (C) 2026 LIghtJUNction

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import {
  getLoopbackCallbackLabel,
  isCompleteOAuthDeviceCode,
  isSafeOAuthDecisionRedirect,
  isSafeOAuthLoopbackRedirect,
  normalizeOAuthDeviceCode,
} from './oauth-utils'

describe('OAuth device code normalization', () => {
  test('formats pasted codes and removes ambiguous or unsupported characters', () => {
    assert.equal(normalizeOAuthDeviceCode('abcd-efgh'), 'ABCD-EFGH')
    assert.equal(normalizeOAuthDeviceCode(' abcd efgh extra '), 'ABCD-EFGH')
    assert.equal(normalizeOAuthDeviceCode('ABCI-O01Z'), 'ABCZ')
  })

  test('requires exactly eight characters from the server alphabet', () => {
    assert.equal(isCompleteOAuthDeviceCode('ABCD-EFGH'), true)
    assert.equal(isCompleteOAuthDeviceCode('ABCD-EFG'), false)
    assert.equal(isCompleteOAuthDeviceCode('ABCI-EFGH'), false)
  })
})

describe('OAuth loopback callback validation', () => {
  test('accepts only the exact IPv4 and IPv6 callback contract', () => {
    assert.equal(
      isSafeOAuthLoopbackRedirect(
        'http://127.0.0.1:49152/oauth/callback'
      ),
      true
    )
    assert.equal(
      isSafeOAuthLoopbackRedirect('http://[::1]:49152/oauth/callback'),
      true
    )
    assert.equal(
      getLoopbackCallbackLabel('http://127.0.0.1:49152/oauth/callback'),
      '127.0.0.1:49152'
    )
  })

  test('accepts only a code or denial result with a valid state', () => {
    const state = 's'.repeat(43)
    assert.equal(
      isSafeOAuthDecisionRedirect(
        `http://127.0.0.1:49152/oauth/callback?code=${'c'.repeat(43)}&state=${state}`
      ),
      true
    )
    assert.equal(
      isSafeOAuthDecisionRedirect(
        `http://[::1]:49152/oauth/callback?error=access_denied&state=${state}`
      ),
      true
    )
    assert.equal(
      isSafeOAuthDecisionRedirect(
        `http://127.0.0.1:49152/oauth/callback?code=${'c'.repeat(43)}&state=${state}&next=https://evil.example`
      ),
      false
    )
    assert.equal(
      isSafeOAuthDecisionRedirect(
        `https://evil.example/oauth/callback?code=${'c'.repeat(43)}&state=${state}`
      ),
      false
    )
  })

  test('rejects remote, ambiguous, privileged, and decorated callback URLs', () => {
    const unsafe = [
      'https://127.0.0.1:49152/oauth/callback',
      'http://localhost:49152/oauth/callback',
      'http://127.1:49152/oauth/callback',
      'http://127.0.0.1.evil.example:49152/oauth/callback',
      'http://127.0.0.1:80/oauth/callback',
      'http://user@127.0.0.1:49152/oauth/callback',
      'http://127.0.0.1:49152/oauth/callback?code=leak',
      'http://127.0.0.1:49152/oauth/callback#fragment',
      'http://127.0.0.1:49152/other',
      'javascript:alert(1)',
    ]

    for (const value of unsafe) {
      assert.equal(isSafeOAuthLoopbackRedirect(value), false, value)
      assert.equal(getLoopbackCallbackLabel(value), null, value)
    }
  })
})
