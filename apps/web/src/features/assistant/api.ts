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
}

export type AssistantCreditStatus = {
  weekly_credit_usd: number
  limit_quota: number
  used_quota: number
  remaining_quota: number
  week_start: number
  resets_at: number
}

export type AssistantStatus = {
  enabled: boolean
  model: string
  credit: AssistantCreditStatus
  developer_access_granted: boolean
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

export type AssistantIntentSummary = {
  intent: string
  count: number
}

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

export async function sendAssistantMessage(message: string): Promise<string> {
  const response = await api.post<AssistantChatPayload>(
    '/api/assistant/chat',
    { message },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return parseAssistantReply(response.data)
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

export async function createAssistantDefaultKey(
  name: string
): Promise<AssistantCreatedKey> {
  const response = await api.post<AssistantAPIResponse<AssistantCreatedKey>>(
    '/api/assistant/tools/create-key',
    { confirmed: true, name },
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
