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
import type { AssistantIntent } from './api'
import type { AssistantPresetId } from './assistant-events'

const INTENT_PRESET: Partial<Record<AssistantIntent, AssistantPresetId>> = {
  onboarding: 'onboarding',
  plan_purchase: 'plan',
  api_key: 'api-key',
  client_setup: 'client-setup',
  cost: 'cost',
  bounty: 'bounty',
  usage: 'usage',
  models: 'models',
  invitation: 'invitation',
  human_support: 'human',
}

export function getAssistantPresetForIntent(
  intent: AssistantIntent | undefined
): AssistantPresetId | undefined {
  return intent ? INTENT_PRESET[intent] : undefined
}
