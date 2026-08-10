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
  const response = await api.get<{
    success: boolean
    data?: AssistantStatus
    message?: string
  }>('/api/assistant/status', {
    disableDuplicate: true,
    skipBusinessError: true,
    skipErrorHandler: true,
  })
  if (!response.data.success || !response.data.data) {
    throw new Error(response.data.message || 'Unable to load assistant status')
  }
  return response.data.data
}
