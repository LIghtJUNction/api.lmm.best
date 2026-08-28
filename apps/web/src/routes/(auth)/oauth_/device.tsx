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
import { createFileRoute } from '@tanstack/react-router'
import { z } from 'zod'

import { DeviceAuthorization } from '@/features/oauth-authorization/device-authorization'
import { requireOAuthAuthentication } from '@/features/oauth-authorization/oauth-route-guard'
import { normalizeOAuthDeviceCode } from '@/features/oauth-authorization/oauth-utils'

const searchSchema = z.object({
  user_code: z.string().trim().max(32).optional(),
})

export const Route = createFileRoute('/(auth)/oauth_/device')({
  validateSearch: searchSchema,
  beforeLoad: ({ location }) => requireOAuthAuthentication(location.href),
  component: OAuthDeviceRoute,
})

function OAuthDeviceRoute() {
  const search = Route.useSearch()
  const normalizedCode = normalizeOAuthDeviceCode(search.user_code ?? '')
  return (
    <DeviceAuthorization
      key={normalizedCode}
      userCode={normalizedCode || undefined}
    />
  )
}
