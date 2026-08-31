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
/*
Copyright (C) 2026 LIghtJUNction
*/
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { api } from '@/lib/api'

import { getStatusDetectionMetrics, getStatusDetectionSummary } from './api'

describe('status detection API failures', () => {
  test('rejects an unsuccessful performance summary', async () => {
    const originalGet = api.get
    api.get = (async () => ({
      data: { success: false, message: 'metrics unavailable', data: {} },
    })) as typeof api.get

    try {
      await assert.rejects(getStatusDetectionSummary(), /metrics unavailable/)
    } finally {
      api.get = originalGet
    }
  })

  test('reports unsuccessful model responses as partial failures', async () => {
    const originalGet = api.get
    api.get = (async (
      _url: string,
      config?: { params?: { model?: string } }
    ) => {
      const modelName = config?.params?.model ?? ''
      if (modelName === 'failed-model') {
        return {
          data: { success: false, message: 'model unavailable', data: {} },
        }
      }
      return {
        data: {
          success: true,
          data: {
            model_name: modelName,
            groups: [
              {
                group: 'default',
                avg_ttft_ms: 100,
                avg_latency_ms: 200,
                success_rate: 99,
                avg_tps: 25,
                series: [],
              },
            ],
          },
        },
      }
    }) as typeof api.get

    try {
      const result = await getStatusDetectionMetrics([
        'healthy-model',
        'failed-model',
      ])

      assert.deepEqual(result.failedModels, ['failed-model'])
      assert.deepEqual(
        result.entries.map((entry) => entry.modelName),
        ['healthy-model']
      )
    } finally {
      api.get = originalGet
    }
  })
})
