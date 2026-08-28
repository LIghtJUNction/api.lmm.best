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

import { AuthorizationConsent } from '@/features/oauth-authorization/authorization-consent'
import { requireOAuthAuthentication } from '@/features/oauth-authorization/oauth-route-guard'

const searchSchema = z.object({
  request: z.string().trim().max(1024).optional(),
})

export const Route = createFileRoute('/(auth)/oauth_/consent')({
  validateSearch: searchSchema,
  beforeLoad: ({ location }) => requireOAuthAuthentication(location.href),
  component: OAuthConsentRoute,
})

function OAuthConsentRoute() {
  const search = Route.useSearch()
  return <AuthorizationConsent request={search.request ?? ''} />
}
