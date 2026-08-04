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
import { afterEach, describe, test } from 'node:test'

import { api } from '@/lib/api'

import {
  listBounties,
  listReceivedBountyTips,
  markReceivedBountyTipsRead,
  thankBountyTip,
  tipChallenge,
} from './api'

const originalGet = api.get
const originalPost = api.post

afterEach(() => {
  api.get = originalGet
  api.post = originalPost
})

describe('open-source bounty lists', () => {
  test('normalizes a null project list from an empty database to an array', async () => {
    api.get = (async () => ({
      data: {
        success: true,
        data: { items: null, total: 0 },
      },
    })) as typeof api.get

    const result = await listBounties()

    assert.deepEqual(result, { items: [], total: 0 })
  })
})

describe('open-source bounty tips', () => {
  test('sends the supplied idempotency key unchanged across a retry', async () => {
    const requests: Array<{
      url: string
      data: unknown
      idempotencyKey: string | undefined
    }> = []

    api.post = (async (url, data, config) => {
      const headers = config?.headers as Record<string, string> | undefined
      requests.push({
        url,
        data,
        idempotencyKey: headers?.['Idempotency-Key'],
      })
      return {
        data: {
          success: true,
          data: {
            challenge: {},
            transferred_quota: 250_000,
            remaining_quota: 750_000,
          },
        },
      }
    }) as typeof api.post

    const idempotencyKey = '56c69ad7-64c3-4c66-91ed-044837157f5f'
    const input = { quota: 250_000, note: 'partial progress' }

    await tipChallenge(42, input, idempotencyKey)
    await tipChallenge(42, input, idempotencyKey)

    assert.deepEqual(requests, [
      {
        url: '/api/open-source-bounties/challenges/42/tip',
        data: input,
        idempotencyKey,
      },
      {
        url: '/api/open-source-bounties/challenges/42/tip',
        data: input,
        idempotencyKey,
      },
    ])
  })

  test('uses recipient-scoped notification and thank endpoints', async () => {
    const gets: string[] = []
    const posts: string[] = []
    api.get = (async (url) => {
      gets.push(url)
      return { data: { success: true, data: [] } }
    }) as typeof api.get
    api.post = (async (url) => {
      posts.push(url)
      return { data: { success: true, data: null } }
    }) as typeof api.post

    await listReceivedBountyTips()
    await markReceivedBountyTipsRead()
    await thankBountyTip(17)

    assert.deepEqual(gets, ['/api/open-source-bounties/tips/received'])
    assert.deepEqual(posts, [
      '/api/open-source-bounties/tips/received/read',
      '/api/open-source-bounties/tips/17/thank',
    ])
  })
})
