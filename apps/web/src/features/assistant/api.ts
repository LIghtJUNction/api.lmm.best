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
import type { QuotaDataItem } from '@/features/dashboard/types'
import type { PricingData } from '@/features/pricing/types'
import type { PlanRecord } from '@/features/subscriptions/types'
import { api } from '@/lib/api'

type AssistantChatPayload = {
  choices?: Array<{
    message?: {
      content?: string
    }
  }>
  error?: {
    message?: string
  }
  message?: string
  lmm_assistant_action?: unknown
}

export type AssistantChatMessage = {
  role: 'user' | 'assistant'
  content: string
}

const ASSISTANT_CONVERSATION_MAX_ITEMS = 12
const ASSISTANT_CONVERSATION_MAX_RUNES = 12_000
const ASSISTANT_MESSAGE_MAX_RUNES = 4_000

export type AssistantFundingStatus = {
  mode: 'super_administrator'
}

export type AssistantStatus = {
  enabled: boolean
  model: string
  funding: AssistantFundingStatus
  developer_access_granted: boolean
}

export type AssistantL1RecommendationAction = {
  type: 'l1_recommendation'
  user_statement: string
  recommendation: string
  confirmation_token: string
}

export type AssistantCreatedKey = {
  id: number
  name: string
  key: string
  group: string
  expired_time: number
}

export type AssistantHandoff = {
  id: number
  user_id: number
  source: 'handoff'
  intent: 'human_support'
  message: string
  status: 'pending' | 'resolved'
  admin_user_id: number
  admin_note: string
  created_at: number
  resolved_at: number
  username?: string
  email?: string
}

export type AssistantIntent =
  | 'onboarding'
  | 'plan_purchase'
  | 'api_key'
  | 'client_setup'
  | 'cost'
  | 'bounty'
  | 'usage'
  | 'models'
  | 'invitation'
  | 'human_support'
  | 'other'

export type AssistantIntentSummary = {
  intent: AssistantIntent
  count: number
}

export type AssistantProfileSummary = {
  profile: string
  count: number
}

export type AssistantFundingSummary = {
  start_timestamp: number
  end_timestamp: number
  requests: number
  prompt_tokens: number
  completion_tokens: number
  total_tokens: number
  quota: number
  cost_usd: number
  remaining_quota: number
  remaining_usd: number
}

export type AssistantReply = {
  content: string
  intent?: AssistantIntent
  action?: AssistantL1RecommendationAction
}

export type AssistantPlanOffers = {
  ok: boolean
  developer_access_granted: boolean
  read_only: boolean
  checkout_available: boolean
  payment_hidden: boolean
  payment_compliance_confirmed: boolean
  plans: PlanRecord[]
  topup_discounts: Record<string, number>
  message?: string
  next_step?: string
  error?: string
}

const ASSISTANT_INTENTS = new Set<AssistantIntent>([
  'onboarding',
  'plan_purchase',
  'api_key',
  'client_setup',
  'cost',
  'bounty',
  'usage',
  'models',
  'invitation',
  'human_support',
  'other',
])

type AssistantAPIResponse<T> = {
  success: boolean
  data?: T
  message?: string
}

function requireAssistantData<T>(
  payload: AssistantAPIResponse<T>,
  fallback: string
): T {
  if (!payload.success || payload.data === undefined) {
    throw new Error(payload.message || fallback)
  }
  return payload.data
}

export function parseAssistantReply(payload: AssistantChatPayload): string {
  const content = payload.choices?.[0]?.message?.content?.trim()
  if (content) return content
  throw new Error(
    payload.error?.message || payload.message || 'Assistant returned no answer'
  )
}

export function parseAssistantIntent(
  value: unknown
): AssistantIntent | undefined {
  if (typeof value !== 'string') return undefined
  const intent = value.trim().toLowerCase() as AssistantIntent
  return ASSISTANT_INTENTS.has(intent) ? intent : undefined
}

export function parseAssistantAction(
  value: unknown
): AssistantL1RecommendationAction | undefined {
  if (!value || typeof value !== 'object') return undefined
  const action = value as Record<string, unknown>
  if (action.type !== 'l1_recommendation') return undefined
  if (
    typeof action.user_statement !== 'string' ||
    typeof action.recommendation !== 'string' ||
    typeof action.confirmation_token !== 'string'
  ) {
    return undefined
  }
  const userStatement = action.user_statement.trim()
  const recommendation = action.recommendation.trim()
  const confirmationToken = action.confirmation_token.trim()
  if (!userStatement || !recommendation || !confirmationToken) return undefined
  return {
    type: 'l1_recommendation',
    user_statement: userStatement,
    recommendation,
    confirmation_token: confirmationToken,
  }
}

function normalizedAssistantHistoryMessage(
  message: AssistantChatMessage
): AssistantChatMessage | null {
  const content = message.content.trim()
  if (!content) return null
  return {
    role: message.role,
    content: [...content].slice(0, ASSISTANT_MESSAGE_MAX_RUNES).join(''),
  }
}

export function buildAssistantConversation(
  history: AssistantChatMessage[],
  currentMessage: string
): AssistantChatMessage[] {
  const current = currentMessage.trim()
  const currentRunes = [...current]
  if (!current || currentRunes.length > ASSISTANT_MESSAGE_MAX_RUNES) {
    throw new Error(
      `Assistant message must be between 1 and ${ASSISTANT_MESSAGE_MAX_RUNES} characters`
    )
  }

  const conversation: AssistantChatMessage[] = [
    { role: 'user', content: current },
  ]
  let totalRunes = currentRunes.length
  for (let index = history.length - 1; index >= 0; index -= 1) {
    if (conversation.length >= ASSISTANT_CONVERSATION_MAX_ITEMS) break
    const message = normalizedAssistantHistoryMessage(history[index])
    if (!message) continue
    const messageRunes = [...message.content].length
    if (totalRunes + messageRunes > ASSISTANT_CONVERSATION_MAX_RUNES) break
    conversation.unshift(message)
    totalRunes += messageRunes
  }

  while (conversation[0]?.role === 'assistant') conversation.shift()
  return conversation
}

export async function sendAssistantMessage(
  message: string,
  history: AssistantChatMessage[] = []
): Promise<AssistantReply> {
  const normalizedMessage = message.trim()
  const messages = buildAssistantConversation(history, normalizedMessage)
  const response = await api.post<AssistantChatPayload>(
    '/api/assistant/chat',
    { message: normalizedMessage, messages },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return {
    content: parseAssistantReply(response.data),
    intent: parseAssistantIntent(response.headers['x-lmm-assistant-intent']),
    action: parseAssistantAction(response.data.lmm_assistant_action),
  }
}

export async function getAssistantStatus(): Promise<AssistantStatus> {
  const response = await api.get<AssistantAPIResponse<AssistantStatus>>(
    '/api/assistant/status',
    {
      disableDuplicate: true,
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  return requireAssistantData(response.data, 'Unable to load assistant status')
}

export async function getAssistantAvailableModels(): Promise<string[]> {
  const response = await api.get<AssistantAPIResponse<string[]>>(
    '/api/user/models',
    {
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  return requireAssistantData(response.data, 'Unable to load available models')
}

export async function getAssistantPricing(): Promise<PricingData> {
  const response = await api.get<PricingData>('/api/assistant/pricing', {
    skipBusinessError: true,
    skipErrorHandler: true,
  })
  if (!response.data.success) {
    throw new Error(response.data.message || 'Unable to load live pricing')
  }
  return response.data
}

export async function getAssistantPlanOffers(): Promise<AssistantPlanOffers> {
  const response = await api.get<AssistantAPIResponse<AssistantPlanOffers>>(
    '/api/assistant/offers',
    {
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  const offers = requireAssistantData(
    response.data,
    'Unable to load live plan offers'
  )
  if (!offers.ok) {
    throw new Error(offers.error || 'Unable to load live plan offers')
  }
  return offers
}

export async function getAssistantUsageData(
  days: 7 | 30 | 90
): Promise<QuotaDataItem[]> {
  const endTimestamp = Math.floor(Date.now() / 1000)
  const response = await api.get<AssistantAPIResponse<QuotaDataItem[]>>(
    '/api/data/self',
    {
      params: {
        start_timestamp: endTimestamp - days * 24 * 60 * 60,
        end_timestamp: endTimestamp,
        default_time: 'day',
      },
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  return requireAssistantData(response.data, 'Failed to fetch usage')
}

export async function createAssistantDefaultKey(
  name: string,
  group: string
): Promise<AssistantCreatedKey> {
  const response = await api.post<AssistantAPIResponse<AssistantCreatedKey>>(
    '/api/assistant/tools/create-key',
    { confirmed: true, name, group },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return requireAssistantData(response.data, 'Unable to create API key')
}

export async function getAssistantHandoff(): Promise<AssistantHandoff | null> {
  const response = await api.get<AssistantAPIResponse<AssistantHandoff | null>>(
    '/api/assistant/handoffs/self',
    {
      disableDuplicate: true,
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  return requireAssistantData(response.data, 'Unable to load support request')
}

export async function submitAssistantHandoff(
  message: string
): Promise<AssistantHandoff> {
  const response = await api.post<AssistantAPIResponse<AssistantHandoff>>(
    '/api/assistant/handoffs',
    { confirmed: true, message },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return requireAssistantData(response.data, 'Unable to contact support')
}

export async function listAssistantHandoffs(
  status: 'pending' | 'resolved' = 'pending'
): Promise<AssistantHandoff[]> {
  const response = await api.get<AssistantAPIResponse<AssistantHandoff[]>>(
    '/api/assistant/admin/handoffs',
    {
      params: { status },
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  return requireAssistantData(response.data, 'Unable to load support requests')
}

export async function getAssistantIntentSummary(
  days = 30
): Promise<AssistantIntentSummary[]> {
  const response = await api.get<
    AssistantAPIResponse<AssistantIntentSummary[]>
  >('/api/assistant/admin/intents', {
    params: { days },
    skipBusinessError: true,
    skipErrorHandler: true,
  })
  return requireAssistantData(response.data, 'Unable to load intent summary')
}

export async function getAssistantProfileSummary(
  days = 30
): Promise<AssistantProfileSummary[]> {
  const response = await api.get<
    AssistantAPIResponse<AssistantProfileSummary[]>
  >('/api/assistant/admin/profiles', {
    params: { days },
    skipBusinessError: true,
    skipErrorHandler: true,
  })
  return requireAssistantData(response.data, 'Unable to load profile summary')
}

export async function getAssistantFundingSummary(
  days = 30
): Promise<AssistantFundingSummary> {
  const response = await api.get<AssistantAPIResponse<AssistantFundingSummary>>(
    '/api/assistant/admin/funding',
    {
      params: { days },
      skipBusinessError: true,
      skipErrorHandler: true,
    }
  )
  return requireAssistantData(response.data, 'Unable to load assistant funding')
}

export async function resolveAssistantHandoff(
  id: number,
  note: string
): Promise<AssistantHandoff> {
  const response = await api.post<AssistantAPIResponse<AssistantHandoff>>(
    `/api/assistant/admin/handoffs/${id}/resolve`,
    { note },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return requireAssistantData(
    response.data,
    'Unable to resolve support request'
  )
}
