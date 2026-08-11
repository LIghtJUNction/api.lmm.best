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

const domWindow = new Window({ url: 'https://console.example.test/' })
for (const key of [
  'window',
  'document',
  'navigator',
  'history',
  'location',
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
  'scrollTo',
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
const {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} = await import('@tanstack/react-router')
const { createInstance } = await import('i18next')
const { I18nextProvider, initReactI18next } = await import('react-i18next')
const { api } = await import('@/lib/api')
const { AssistantActivationTool } = await import('./assistant-activation-tool')

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

const pendingRequest = {
  id: 9,
  status: 'pending' as const,
  reason: 'Need access for a test integration.',
  admin_note: '',
  created_at: 1_786_400_000,
  reviewed_at: 0,
}
const approvedRequest = {
  ...pendingRequest,
  status: 'approved' as const,
  admin_note: 'Approved for testing.',
  reviewed_at: 1_786_500_000,
}

async function flushEffects() {
  await new Promise((resolve) => setTimeout(resolve, 25))
}

async function renderTool(onContinueSetup: () => void) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const rootRoute = createRootRoute({
    component: () => (
      <QueryClientProvider client={queryClient}>
        <I18nextProvider i18n={i18n}>
          <AssistantActivationTool onContinueSetup={onContinueSetup} />
        </I18nextProvider>
      </QueryClientProvider>
    ),
  })
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: () => null,
  })
  const walletRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/wallet',
    component: () => null,
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute, walletRoute]),
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)

  await act(async () => {
    root.render(<RouterProvider router={router} />)
    await flushEffects()
  })
  await act(flushEffects)
  return { container, queryClient, root }
}

function findButton(text: string): HTMLButtonElement {
  const button = [
    ...document.querySelectorAll<HTMLButtonElement>('button'),
  ].find((candidate) => candidate.textContent?.includes(text))
  assert.ok(button, `Could not find button containing ${text}`)
  return button
}

async function setTextareaValue(textarea: HTMLTextAreaElement, value: string) {
  const setValue = Object.getOwnPropertyDescriptor(
    HTMLTextAreaElement.prototype,
    'value'
  )?.set
  assert.ok(setValue)
  await act(async () => {
    setValue.call(textarea, value)
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushEffects()
  })
}

async function waitForCondition(
  condition: () => boolean,
  failureMessage: string
) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (condition()) return
    await flushEffects()
  }
  throw new Error(`${failureMessage}: ${document.body.textContent}`)
}

async function unmount(rendered: Awaited<ReturnType<typeof renderTool>>) {
  await act(async () => rendered.root.unmount())
  rendered.queryClient.clear()
  rendered.container.remove()
}

afterEach(() => {
  api.get = originalGet
  api.post = originalPost
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('AssistantActivationTool', () => {
  test('requires a trimmed five-character reason before submitting', async () => {
    api.get = (async () => ({
      data: { success: true, data: null },
    })) as typeof api.get
    let submittedReason: string | undefined
    api.post = (async (url: string, data: unknown) => {
      assert.equal(url, '/api/user/developer-access/request')
      submittedReason = (data as { reason: string }).reason
      return {
        data: {
          success: true,
          data: { ...pendingRequest, reason: submittedReason },
        },
      }
    }) as typeof api.post

    const rendered = await renderTool(() => undefined)
    try {
      const textarea = document.querySelector('textarea')
      assert.ok(textarea)
      const submitButton = findButton('Send free review request')
      assert.equal(submitButton.disabled, true)
      assert.equal(
        document.body.textContent?.includes('Application reason is required.'),
        true
      )

      await setTextareaValue(textarea, 'abcd')
      assert.equal(submitButton.disabled, true)
      assert.equal(
        document.body.textContent?.includes(
          'Application reason must contain at least 5 characters.'
        ),
        true
      )

      await setTextareaValue(textarea, '  abcde  ')
      assert.equal(submitButton.disabled, false)

      await act(async () => {
        submitButton.click()
        await flushEffects()
      })
      await waitForCondition(
        () => submittedReason !== undefined,
        'Valid request was not submitted'
      )
      assert.equal(submittedReason, 'abcde')
    } finally {
      await unmount(rendered)
    }
  })

  test('refreshes a pending request and opens setup after approval', async () => {
    let getCalls = 0
    api.get = (async (url: string) => {
      assert.equal(url, '/api/user/developer-access/request')
      getCalls += 1
      return {
        data: {
          success: true,
          data: getCalls === 1 ? pendingRequest : approvedRequest,
        },
      }
    }) as typeof api.get

    let continueCalls = 0
    const rendered = await renderTool(() => {
      continueCalls += 1
    })
    try {
      await waitForCondition(
        () =>
          document.body.textContent?.includes('waiting for administrator') ===
          true,
        'Pending approval state did not render'
      )
      assert.equal(getCalls, 1)
      assert.ok(findButton('Refresh'))

      await act(async () => {
        findButton('Refresh').click()
        await flushEffects()
      })
      await waitForCondition(
        () =>
          document.body.textContent?.includes('L1 access approved') === true,
        'Approved state did not render after refresh'
      )
      assert.equal(getCalls, 2)

      await act(async () => {
        findButton('Continue setup').click()
        await flushEffects()
      })
      assert.equal(continueCalls, 1)
    } finally {
      await unmount(rendered)
    }
  })
})
