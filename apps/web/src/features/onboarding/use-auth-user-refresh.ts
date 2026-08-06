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
import { useCallback, useEffect, useRef } from 'react'

import { getSelf } from '@/lib/api'
import { useAuthStore, type AuthUser } from '@/stores/auth-store'

export function useAuthUserRefresh() {
  const setUser = useAuthStore((state) => state.auth.setUser)
  const inFlightRef = useRef<Promise<AuthUser | null> | null>(null)

  const refreshUser = useCallback(() => {
    if (inFlightRef.current) return inFlightRef.current

    const request = (async () => {
      try {
        const response = await getSelf()
        if (response?.success && response.data) {
          const refreshedUser = response.data as AuthUser
          setUser(refreshedUser)
          return refreshedUser
        }
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error('Failed to refresh authenticated user:', error)
      }

      return null
    })()

    inFlightRef.current = request
    void request.finally(() => {
      if (inFlightRef.current === request) {
        inFlightRef.current = null
      }
    })

    return request
  }, [setUser])

  useEffect(() => {
    void refreshUser()

    const handleFocus = () => {
      void refreshUser()
    }
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        void refreshUser()
      }
    }

    window.addEventListener('focus', handleFocus)
    document.addEventListener('visibilitychange', handleVisibilityChange)

    return () => {
      window.removeEventListener('focus', handleFocus)
      document.removeEventListener('visibilitychange', handleVisibilityChange)
    }
  }, [refreshUser])

  return { refreshUser }
}
