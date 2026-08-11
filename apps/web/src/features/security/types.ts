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
*/

export type SecurityMetricUnit = 'count' | 'percent'

export type SecurityRiskMetric = {
  key: string
  label?: string
  value: number
  unit: SecurityMetricUnit
}

export type SecurityChargeAction = 'block' | 'review' | 'deduct' | 'suspend'

export type SecurityChargeRule = {
  id: string
  rule: string
  action: SecurityChargeAction | string
  amount?: number | null
  currency?: string | null
  scope?: string | null
}

/**
 * Public security data is deliberately optional. The initial frontend can
 * render the policy summary without inventing statistics or charge amounts;
 * the backend can fill these fields when the public overview endpoint exists.
 */
export type SecurityOverview = {
  generated_at?: string | number | null
  period_label?: string | null
  metrics?: SecurityRiskMetric[] | null
  violation_charges?: SecurityChargeRule[] | null
}

export type SecurityOverviewResponse = {
  success: boolean
  message?: string
  data?: SecurityOverview
}
