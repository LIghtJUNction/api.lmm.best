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
import type { PricingModel } from '@/features/pricing/types'

export type AssistantCostEstimate = {
  inputRatePerMillionUSD: number
  outputRatePerMillionUSD: number
  totalUSD: number
}

export function calculateAssistantTextCost(
  model: PricingModel,
  groupRatio: number,
  inputTokens: number,
  outputTokens: number
): AssistantCostEstimate | null {
  if (
    model.quota_type !== 0 ||
    model.billing_mode === 'tiered_expr' ||
    !Number.isFinite(model.model_ratio) ||
    !Number.isFinite(model.completion_ratio) ||
    !Number.isFinite(groupRatio) ||
    !Number.isFinite(inputTokens) ||
    !Number.isFinite(outputTokens) ||
    groupRatio < 0 ||
    inputTokens < 0 ||
    outputTokens < 0
  ) {
    return null
  }

  const inputRatePerMillionUSD = model.model_ratio * 2 * groupRatio
  const outputRatePerMillionUSD =
    inputRatePerMillionUSD * model.completion_ratio
  return {
    inputRatePerMillionUSD,
    outputRatePerMillionUSD,
    totalUSD:
      (inputTokens / 1_000_000) * inputRatePerMillionUSD +
      (outputTokens / 1_000_000) * outputRatePerMillionUSD,
  }
}
