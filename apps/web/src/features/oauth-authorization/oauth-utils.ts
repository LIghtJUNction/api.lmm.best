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
const oauthDeviceAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
const oauthDeviceAlphabetSet = new Set(oauthDeviceAlphabet)
const oauthCallbackPattern =
  /^http:\/\/(?:127\.0\.0\.1|\[::1\]):[0-9]+\/oauth\/callback$/
const oauthDecisionCallbackPattern =
  /^http:\/\/(?:127\.0\.0\.1|\[::1\]):[0-9]+\/oauth\/callback\?[^#]+$/

export function normalizeOAuthDeviceCode(value: string): string {
  const compact = [...value.toUpperCase()]
    .filter((character) => oauthDeviceAlphabetSet.has(character))
    .slice(0, 8)
    .join('')
  if (compact.length <= 4) return compact
  return `${compact.slice(0, 4)}-${compact.slice(4)}`
}

export function isCompleteOAuthDeviceCode(value: string): boolean {
  return /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$/.test(
    normalizeOAuthDeviceCode(value)
  )
}

export function getLoopbackCallbackLabel(value: string): string | null {
  const parsed = parseSafeLoopbackCallback(value, false)
  if (!parsed) return null
  return `${parsed.hostname}:${parsed.port}`
}

export function isSafeOAuthLoopbackRedirect(value: string): boolean {
  return parseSafeLoopbackCallback(value, false) !== null
}

export function isSafeOAuthDecisionRedirect(value: string): boolean {
  const parsed = parseSafeLoopbackCallback(value, true)
  if (!parsed) return false

  const keys = [...parsed.searchParams.keys()]
  if (new Set(keys).size !== keys.length || !parsed.searchParams.has('state')) {
    return false
  }
  const state = parsed.searchParams.get('state') ?? ''
  if (!/^[A-Za-z0-9._~-]{32,512}$/.test(state)) return false

  const code = parsed.searchParams.get('code')
  const error = parsed.searchParams.get('error')
  if (code != null) {
    return keys.length === 2 && error == null && /^[A-Za-z0-9_-]{32,512}$/.test(code)
  }
  return keys.length === 2 && error === 'access_denied'
}

function parseSafeLoopbackCallback(
  value: string,
  allowQuery: boolean
): URL | null {
  const pattern = allowQuery
    ? oauthDecisionCallbackPattern
    : oauthCallbackPattern
  if (!pattern.test(value)) {
    return null
  }

  let parsed: URL
  try {
    parsed = new URL(value)
  } catch {
    return null
  }

  const hostname = parsed.hostname.toLowerCase()
  const isLoopback = hostname === '127.0.0.1' || hostname === '[::1]'
  const port = Number(parsed.port)
  if (
    parsed.protocol !== 'http:' ||
    !isLoopback ||
    !Number.isInteger(port) ||
    port < 1024 ||
    port > 65535 ||
    parsed.pathname !== '/oauth/callback' ||
    parsed.username !== '' ||
    parsed.password !== '' ||
    (!allowQuery && parsed.search !== '') ||
    parsed.hash !== ''
  ) {
    return null
  }
  return parsed
}
