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
import { afterEach, describe, test } from 'node:test'

import { useAuthStore } from '@/stores/auth-store'

import { requireOAuthAuthentication } from './oauth-route-guard'

const oauthLocation = {
  href: 'https://dashboard.example.com/oauth/consent?request=opaque',
  pathname: '/oauth/consent',
}

afterEach(() => useAuthStore.getState().auth.reset('complete'))

describe('OAuth route authentication guard', () => {
  test('sends anonymous users to sign-in with the complete OAuth return URL', () => {
    let thrown: unknown
    try {
      requireOAuthAuthentication(oauthLocation.href)
    } catch (error) {
      thrown = error
    }

    assert.ok(thrown && typeof thrown === 'object')
    const redirect = thrown as {
      options?: { to?: string; search?: { redirect?: string } }
    }
    assert.equal(redirect.options?.to, '/sign-in')
    assert.equal(redirect.options?.search?.redirect, oauthLocation.href)
  })

  test('allows authenticated users to continue on both OAuth pages', () => {
    useAuthStore.setState((state) => ({
      auth: {
        ...state.auth,
        user: { id: 9, username: 'oauth-user', role: 1 },
        accessToken: 'browser-access-token',
      },
    }))

    assert.equal(requireOAuthAuthentication(oauthLocation.href), undefined)
    assert.equal(
      requireOAuthAuthentication(
        'https://dashboard.example.com/oauth/device?user_code=ABCD-EFGH'
      ),
      undefined
    )
  })
})
