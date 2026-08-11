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

const domWindow = new Window({
  url: 'https://console.example.test/admin/users',
})
for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'HTMLButtonElement',
  'HTMLTextAreaElement',
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
const { QueryClient, QueryClientProvider } =
  await import('@tanstack/react-query')
const { createInstance } = await import('i18next')
const { I18nextProvider, initReactI18next } = await import('react-i18next')
const { api } = await import('@/lib/api')
const { AssistantLeadsPanel } = await import('./assistant-leads-panel')

const originalGet = api.get
const originalPost = api.post
const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

const i18n = createInstance()
await i18n.use(initReactI18next).init({
  lng: 'en',
  resources: { en: { translation: {} } },
})

async function flushQueries() {
  await new Promise((resolve) => setTimeout(resolve, 20))
}

async function waitForCondition(
  condition: () => boolean,
  failureMessage: string
) {
  for (let attempt = 0; attempt < 75; attempt += 1) {
    if (condition()) return
    await flushQueries()
  }
  throw new Error(`${failureMessage}: ${document.body.textContent}`)
}

function findButton(text: string) {
  const button = [
    ...document.querySelectorAll<HTMLButtonElement>('button'),
  ].find((candidate) => candidate.textContent?.includes(text))
  assert.ok(button, `Could not find button containing ${text}`)
  return button
}

afterEach(() => {
  api.get = originalGet
  api.post = originalPost
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('AssistantLeadsPanel', () => {
  test('shows pending and resolved queues and moves a resolved request', async () => {
    let pending = [
      {
        id: 1,
        user_id: 7,
        source: 'handoff',
        intent: 'human_support',
        message: 'I need help configuring Claude Code.',
        status: 'pending',
        admin_user_id: 0,
        admin_note: '',
        created_at: 1_786_300_000,
        resolved_at: 0,
        username: 'pending-user',
        email: 'pending@example.test',
      },
    ]
    let resolved = [
      {
        id: 2,
        user_id: 8,
        source: 'handoff',
        intent: 'human_support',
        message: 'My previous request.',
        status: 'resolved',
        admin_user_id: 3,
        admin_note: 'Configuration confirmed.',
        created_at: 1_786_200_000,
        resolved_at: 1_786_210_000,
        username: 'resolved-user',
        email: 'resolved@example.test',
      },
    ]
    const requestedStatuses: unknown[] = []

    api.get = (async (
      url: string,
      config?: { params?: Record<string, unknown> }
    ) => {
      if (url === '/api/assistant/admin/handoffs') {
        const status = config?.params?.status
        requestedStatuses.push(status)
        return {
          data: {
            success: true,
            data: status === 'resolved' ? resolved : pending,
          },
        }
      }
      if (url === '/api/assistant/admin/intents') {
        return {
          data: {
            success: true,
            data: [
              { intent: 'client_setup', count: 4 },
              { intent: 'human_support', count: 2 },
            ],
          },
        }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    api.post = (async (url: string) => {
      assert.equal(url, '/api/assistant/admin/handoffs/1/resolve')
      const updated = {
        ...pending[0],
        status: 'resolved',
        admin_user_id: 3,
        resolved_at: 1_786_310_000,
      }
      pending = []
      resolved = [updated, ...resolved]
      return { data: { success: true, data: updated } }
    }) as typeof api.post

    const container = document.createElement('div')
    document.body.append(container)
    const root = createRoot(container)
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })

    await act(async () => {
      root.render(
        <QueryClientProvider client={queryClient}>
          <I18nextProvider i18n={i18n}>
            <AssistantLeadsPanel />
          </I18nextProvider>
        </QueryClientProvider>
      )
      await flushQueries()
    })
    await act(async () =>
      waitForCondition(
        () => container.textContent?.includes('pending-user') === true,
        'Pending queue did not load'
      )
    )

    assert.ok(requestedStatuses.includes('pending'))
    assert.ok(requestedStatuses.includes('resolved'))
    assert.match(container.textContent ?? '', /6 questions in 30 days/)

    await act(async () => {
      findButton('Resolved').click()
      await flushQueries()
    })
    assert.match(container.textContent ?? '', /resolved-user/)
    assert.match(container.textContent ?? '', /Configuration confirmed\./)
    assert.match(container.textContent ?? '', /Administrator resolution/)

    await act(async () => {
      findButton('Pending').click()
      await flushQueries()
      findButton('Mark resolved').click()
      await flushQueries()
    })
    await act(async () =>
      waitForCondition(
        () =>
          container.textContent?.includes(
            'No pending human-support requests.'
          ) === true,
        'Resolved request did not leave the pending queue'
      )
    )

    await act(async () => {
      findButton('Resolved').click()
      await flushQueries()
    })
    assert.match(container.textContent ?? '', /pending-user/)
    assert.match(
      container.textContent ?? '',
      /I need help configuring Claude Code\./
    )

    await act(async () => root.unmount())
    queryClient.clear()
  })
})
