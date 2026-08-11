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
import assert from 'node:assert/strict'
import { after, afterEach, describe, test } from 'node:test'

import { Window } from 'happy-dom'

import type { User } from '../types'

const domWindow = new Window({
  url: 'https://console.example.test/admin/users',
})
for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'HTMLButtonElement',
  'SVGElement',
  'Node',
  'Element',
  'Event',
  'MouseEvent',
  'PointerEvent',
  'FocusEvent',
  'CustomEvent',
  'MutationObserver',
  'ResizeObserver',
  'requestAnimationFrame',
  'cancelAnimationFrame',
  'getComputedStyle',
] as const) {
  Object.defineProperty(globalThis, key, {
    configurable: true,
    value: domWindow[key],
  })
}

const { act } = await import('react')
const { createRoot } = await import('react-dom/client')
const { createInstance } = await import('i18next')
const { I18nextProvider, initReactI18next } = await import('react-i18next')
const { api } = await import('@/lib/api')
const { UserTrustLevelCell } = await import('./user-trust-level-cell')
const { UsersProvider } = await import('./users-provider')

const originalPost = api.post
const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

const i18n = createInstance()
await i18n.use(initReactI18next).init({
  lng: 'en',
  resources: {
    en: {
      translation: {
        'Decrease trust level': 'Decrease trust level',
        'Increase trust level': 'Increase trust level',
      },
    },
  },
})

function createUser(level: number, role = 1): User {
  return {
    id: 7,
    username: 'level-user',
    display_name: 'Level User',
    quota: 0,
    used_quota: 0,
    request_count: 0,
    group: 'default',
    status: 1,
    role,
    trust_level_info: { level },
  }
}

async function renderCell(user: User) {
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => {
    root.render(
      <I18nextProvider i18n={i18n}>
        <UsersProvider>
          <UserTrustLevelCell user={user} />
        </UsersProvider>
      </I18nextProvider>
    )
  })
  return { container, root }
}

function levelButton(container: HTMLElement, label: string) {
  const button = container.querySelector<HTMLButtonElement>(
    `button[aria-label="${label}"]`
  )
  assert.ok(button, `Could not find ${label} button`)
  return button
}

afterEach(() => {
  api.post = originalPost
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('UserTrustLevelCell', () => {
  test('places decrease on the left and increase on the right', async () => {
    const { container, root } = await renderCell(createUser(2))
    const buttons = [...container.querySelectorAll('button')]
    assert.equal(buttons[0]?.getAttribute('aria-label'), 'Decrease trust level')
    assert.equal(buttons[1]?.getAttribute('aria-label'), 'Increase trust level')
    await act(async () => root.unmount())
  })

  test('updates an ordinary user by exactly one level', async () => {
    const requests: unknown[] = []
    api.post = (async (url: string, payload: unknown) => {
      requests.push({ url, payload })
      return { data: { success: true } }
    }) as typeof api.post

    const { container, root } = await renderCell(createUser(2))
    await act(async () => {
      levelButton(container, 'Increase trust level').click()
      await new Promise((resolve) => setTimeout(resolve, 0))
    })

    assert.deepEqual(requests, [
      {
        url: '/api/user/manage',
        payload: { id: 7, action: 'set_trust_level', value: 3 },
      },
    ])
    await act(async () => root.unmount())
  })

  test('disables unavailable boundaries and administrator controls', async () => {
    const l0 = await renderCell(createUser(0))
    assert.equal(
      levelButton(l0.container, 'Decrease trust level').disabled,
      true
    )
    assert.equal(
      levelButton(l0.container, 'Increase trust level').disabled,
      false
    )
    await act(async () => l0.root.unmount())

    const administrator = await renderCell(createUser(5, 10))
    assert.equal(
      levelButton(administrator.container, 'Decrease trust level').disabled,
      true
    )
    assert.equal(
      levelButton(administrator.container, 'Increase trust level').disabled,
      true
    )
    await act(async () => administrator.root.unmount())
  })
})
