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
import type { ModelPerformanceSnapshot, StatusGroup } from '../types'

type GroupAccumulator = {
  models: Set<string>
  latencies: number[]
  throughputs: number[]
  successRates: number[]
  trendByTimestamp: Map<number, number[]>
}

function average(values: number[], predicate: (value: number) => boolean) {
  const valid = values.filter(predicate)
  if (valid.length === 0) return Number.NaN
  return valid.reduce((sum, value) => sum + value, 0) / valid.length
}

/**
 * Converts per-model performance responses into one stable row per group.
 * The API does not expose request counts for each group, so values are
 * intentionally averaged per model rather than presented as weighted totals.
 */
export function aggregateStatusGroups(
  entries: ModelPerformanceSnapshot[]
): StatusGroup[] {
  const groups = new Map<string, GroupAccumulator>()

  for (const entry of entries) {
    for (const group of entry.groups) {
      const name = group.group.trim()
      if (!name) continue
      const accumulator = groups.get(name) ?? {
        models: new Set<string>(),
        latencies: [],
        throughputs: [],
        successRates: [],
        trendByTimestamp: new Map<number, number[]>(),
      }

      accumulator.models.add(entry.modelName)
      if (Number.isFinite(group.avg_latency_ms) && group.avg_latency_ms > 0) {
        accumulator.latencies.push(group.avg_latency_ms)
      }
      if (Number.isFinite(group.avg_tps) && group.avg_tps > 0) {
        accumulator.throughputs.push(group.avg_tps)
      }
      if (Number.isFinite(group.success_rate)) {
        accumulator.successRates.push(group.success_rate)
      }
      for (const point of group.series ?? []) {
        if (
          !Number.isFinite(point.ts) ||
          !Number.isFinite(point.success_rate)
        ) {
          continue
        }
        const rates = accumulator.trendByTimestamp.get(point.ts) ?? []
        rates.push(point.success_rate)
        accumulator.trendByTimestamp.set(point.ts, rates)
      }
      groups.set(name, accumulator)
    }
  }

  return [...groups.entries()]
    .map(([group, accumulator]) => ({
      group,
      avgLatencyMs: average(accumulator.latencies, (value) => value > 0),
      avgTps: average(accumulator.throughputs, (value) => value > 0),
      successRate: average(accumulator.successRates, Number.isFinite),
      trend: [...accumulator.trendByTimestamp.entries()]
        .sort(([left], [right]) => left - right)
        .map(([, rates]) => average(rates, Number.isFinite)),
      modelCount: accumulator.models.size,
    }))
    .sort((left, right) => left.group.localeCompare(right.group))
}
