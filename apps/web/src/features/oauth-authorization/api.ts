/*
Copyright (C) 2026 LIghtJUNction

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/
import { api } from '@/lib/api'

import type {
  OAuthAuthorizationDecision,
  OAuthAuthorizationPreview,
  OAuthDeviceDecision,
} from './types'

type ApiEnvelope<T> = {
  success: boolean
  message?: string
  data?: T
}

function requireData<T>(payload: ApiEnvelope<T>): T {
  if (!payload.success || payload.data === undefined) {
    throw new Error(payload.message || 'OAuth request failed')
  }
  return payload.data
}

export async function getOAuthAuthorizationPreview(request: string) {
  const response = await api.get<ApiEnvelope<OAuthAuthorizationPreview>>(
    `/api/oauth/authorization/${encodeURIComponent(request)}`,
    {
      skipBusinessError: true,
      skipErrorHandler: true,
      disableDuplicate: true,
    }
  )
  return requireData(response.data)
}

export async function decideOAuthAuthorization(
  request: string,
  approve: boolean
) {
  const response = await api.post<ApiEnvelope<OAuthAuthorizationDecision>>(
    `/api/oauth/authorization/${encodeURIComponent(request)}`,
    { approve },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return requireData(response.data)
}

export async function decideOAuthDevice(
  userCode: string,
  approve: boolean
) {
  const response = await api.post<ApiEnvelope<OAuthDeviceDecision>>(
    '/api/oauth/device',
    { user_code: userCode, approve },
    { skipBusinessError: true, skipErrorHandler: true }
  )
  return requireData(response.data)
}
