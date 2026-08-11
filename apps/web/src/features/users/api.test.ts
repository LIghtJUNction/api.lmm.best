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

import { api } from '@/lib/api'

import { getUsers, searchUsers } from './api'

describe('user management API filters', () => {
  test('passes the L0 filter to the paginated user endpoint', async () => {
    const originalGet = api.get
    let requestConfig: unknown
    api.get = (async (url: string, config?: unknown) => {
      assert.equal(url, '/api/user/')
      requestConfig = config
      return { data: { success: true, data: { items: [], total: 0 } } }
    }) as typeof api.get

    try {
      await getUsers({ p: 2, page_size: 20, trust_level: 0 })
      assert.deepEqual(requestConfig, {
        params: {
          p: 2,
          page_size: 20,
          trust_level: 0,
          sort_by: undefined,
          sort_order: undefined,
        },
      })
    } finally {
      api.get = originalGet
    }
  })

  test('passes the L0 filter to user search', async () => {
    const originalGet = api.get
    let requestUrl = ''
    api.get = (async (url: string) => {
      requestUrl = url
      return { data: { success: true, data: { items: [], total: 0 } } }
    }) as typeof api.get

    try {
      await searchUsers({ keyword: 'alice', trust_level: 0 })
      const [path, query = ''] = requestUrl.split('?')
      assert.equal(path, '/api/user/search')
      const params = new URLSearchParams(query)
      assert.equal(params.get('keyword'), 'alice')
      assert.equal(params.get('trust_level'), '0')
    } finally {
      api.get = originalGet
    }
  })
})
