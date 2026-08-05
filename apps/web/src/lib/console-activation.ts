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
import type { AuthUser } from '@/stores/auth-store'

const ADMIN_ROLE = 10

export function isConsoleActivated(user: AuthUser | null | undefined): boolean {
  if (!user) return false
  if (user.role >= ADMIN_ROLE) return true
  return user.permissions?.console_activated_at !== 0
}

export function getAuthenticatedLandingRoute(
  user: AuthUser | null | undefined
): '/open-source-bounties' | '/workspace' {
  return isConsoleActivated(user) ? '/open-source-bounties' : '/workspace'
}

export function isContributorRoute(pathname: string): boolean {
  return [
    '/challenges',
    '/wallet',
    '/profile',
    '/developer-access',
    '/workspace',
    '/support',
  ].some((path) => pathname === path || pathname.startsWith(`${path}/`))
}

export function isRestrictedPublicRoute(pathname: string): boolean {
  return ['/about', '/pricing', '/rankings'].some(
    (path) => pathname === path || pathname.startsWith(`${path}/`)
  )
}
