/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
*/
import assert from 'node:assert/strict'
import { after, afterEach, describe, test } from 'node:test'

import { Window } from 'happy-dom'

import type { ApiRequestConfig } from '@/lib/api'
import type { AuthUser } from '@/stores/auth-store'

const domWindow = new Window({ url: 'https://console.example.test/' })
for (const key of [
  'window',
  'document',
  'navigator',
  'history',
  'location',
  'HTMLElement',
  'SVGElement',
  'Node',
  'Element',
  'Event',
  'CustomEvent',
  'MutationObserver',
  'requestAnimationFrame',
  'cancelAnimationFrame',
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
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} = await import('@tanstack/react-router')
const { createInstance } = await import('i18next')
const { I18nextProvider, initReactI18next } = await import('react-i18next')
const { api } = await import('@/lib/api')
const { consumeQueuedAssistantMessage, subscribeToAssistantOpen } =
  await import('@/features/assistant/assistant-events')
const { useAuthStore } = await import('@/stores/auth-store')
const { GettingStarted } = await import('./getting-started')

const originalGet = api.get
const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

const i18n = createInstance()
await i18n.use(initReactI18next).init({
  lng: 'en',
  resources: { en: { translation: {} } },
})

const user: AuthUser = {
  id: 7,
  username: 'new-user',
  role: 1,
  developer_access_granted: false,
}

const emptyTopupInfo = {
  enable_online_topup: false,
  enable_stripe_topup: false,
  pay_methods: [],
  min_topup: 1,
  stripe_min_topup: 1,
  amount_options: [],
  discount: {},
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((nextResolve) => {
    resolve = nextResolve
  })
  return { promise, resolve }
}

async function flushEffects() {
  await new Promise((resolve) => setTimeout(resolve, 20))
}

function makeRouter() {
  const rootRoute = createRootRoute({ component: Outlet })
  const gettingStartedRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/getting-started',
    component: GettingStarted,
  })
  const emptyRoutes = ['/wallet', '/support', '/keys', '/dashboard'].map(
    (path) =>
      createRoute({
        getParentRoute: () => rootRoute,
        path,
        component: () => null,
      })
  )
  return createRouter({
    routeTree: rootRoute.addChildren([gettingStartedRoute, ...emptyRoutes]),
    history: createMemoryHistory({ initialEntries: ['/getting-started'] }),
  })
}

async function renderPage(
  topupResponse: Promise<{ data: Record<string, unknown> }>,
  bountyCapability = false,
  bountyResponse: { data: Record<string, unknown> } | Error = {
    data: {
      success: true,
      data: { items: [], total: 0, page: 1, page_size: 50 },
    },
  },
  accessRequest: Record<string, unknown> | null = null,
  userOverride: Partial<AuthUser> = {}
) {
  const currentUser = { ...user, ...userOverride }
  const gets: string[] = []
  const getConfigs: Array<ApiRequestConfig | undefined> = []
  api.get = (async (url, config) => {
    gets.push(url)
    getConfigs.push(config)
    if (url === '/api/user/self') {
      return { data: { success: true, data: currentUser } }
    }
    if (url === '/api/user/topup/info') return topupResponse
    if (url === '/api/user/developer-access/request') {
      return { data: { success: true, data: accessRequest } }
    }
    if (url === '/api/status') {
      return {
        data: {
          success: true,
          data: {
            backend_capabilities: {
              bounty_notifications: false,
              bounty_challenge_cancel: false,
              bounty_public_read: bountyCapability,
              self_oauth_unbind: false,
              responses_websocket: false,
            },
          },
        },
      }
    }
    if (url.startsWith('/api/open-source-bounties?')) {
      if (bountyResponse instanceof Error) throw bountyResponse
      return bountyResponse
    }
    return { data: { success: true, data: [] } }
  }) as typeof api.get
  useAuthStore.getState().auth.setUser(currentUser)

  const queryClient = new QueryClient({
    // Keep the test honest: ChallengeList must disable retries itself for a
    // best-effort route probe, rather than relying on a test-only default.
    defaultOptions: { queries: { retry: 3 } },
  })
  const router = makeRouter()
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => {
    root.render(
      <QueryClientProvider client={queryClient}>
        <I18nextProvider i18n={i18n}>
          <RouterProvider router={router} />
        </I18nextProvider>
      </QueryClientProvider>
    )
    await flushEffects()
  })
  return { container, root, queryClient, gets, getConfigs }
}

async function unmountPage(page: Awaited<ReturnType<typeof renderPage>>) {
  await act(async () => page.root.unmount())
  page.queryClient.clear()
  page.container.remove()
}

afterEach(() => {
  api.get = originalGet
  useAuthStore.getState().auth.reset('complete')
  window.localStorage.clear()
  window.sessionStorage.clear()
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('getting started payment availability', () => {
  test('shows the mandatory three-step tutorial and derives progress from account state', async () => {
    const l0Page = await renderPage(
      Promise.resolve({ data: { success: true, data: emptyTopupInfo } })
    )
    assert.equal(
      l0Page.container.textContent?.includes('Three steps to get started'),
      true
    )
    assert.equal(l0Page.container.textContent?.includes('0/3'), true)
    assert.equal(
      l0Page.container.textContent?.includes('L0 tutorial required'),
      true
    )
    assert.equal(l0Page.container.textContent?.includes('Current step'), true)
    await unmountPage(l0Page)

    const l1Page = await renderPage(
      Promise.resolve({ data: { success: true, data: emptyTopupInfo } }),
      false,
      undefined,
      null,
      {
        developer_access_granted: true,
        onboarding: {
          activation_complete: true,
          credential_complete: false,
          first_request_complete: false,
          stage: 'credential',
        },
      }
    )
    assert.equal(l1Page.container.textContent?.includes('1/3'), true)
    assert.equal(l1Page.container.textContent?.includes('Create API key'), true)
    assert.equal(l1Page.container.textContent?.includes('Continue setup'), true)
    await unmountPage(l1Page)
  })

  test('offers guided questions that keep the onboarding action in the assistant input', async () => {
    const opened: Array<string | undefined> = []
    const messages: Array<string | undefined> = []
    const unsubscribe = subscribeToAssistantOpen((preset) => {
      opened.push(preset ?? undefined)
      messages.push(consumeQueuedAssistantMessage())
    })
    const page = await renderPage(
      Promise.resolve({ data: { success: true, data: emptyTopupInfo } })
    )

    const question = [...page.container.querySelectorAll('button')].find(
      (button) =>
        button.textContent?.includes(
          'What are my Base URL, model ID, and API key?'
        )
    )
    assert.ok(question)
    await act(async () => {
      question.click()
      await flushEffects()
    })

    assert.deepEqual(opened, [undefined])
    assert.deepEqual(messages, ['What are my Base URL, model ID, and API key?'])
    await unmountPage(page)
    unsubscribe()
  })

  test('opens onboarding guidance once while administrator review is pending', async () => {
    const opened: Array<string | undefined> = []
    const unsubscribe = subscribeToAssistantOpen((preset) =>
      opened.push(preset)
    )
    const pendingRequest = {
      id: 9901,
      status: 'pending',
      reason: '',
      admin_note: '',
      created_at: 1,
      reviewed_at: 0,
    }

    const first = await renderPage(
      Promise.resolve({ data: { success: true, data: emptyTopupInfo } }),
      false,
      { data: { success: true, data: [] } },
      pendingRequest
    )
    assert.deepEqual(opened, ['onboarding'])
    await unmountPage(first)

    const second = await renderPage(
      Promise.resolve({ data: { success: true, data: emptyTopupInfo } }),
      false,
      { data: { success: true, data: [] } },
      pendingRequest
    )
    assert.deepEqual(opened, ['onboarding'])
    await unmountPage(second)
    unsubscribe()
  })

  test('shows a non-actionable checking state while payment availability loads', async () => {
    const topup = deferred<{ data: Record<string, unknown> }>()
    const page = await renderPage(topup.promise)
    assert.equal(
      page.container.textContent?.includes('Checking payment availability...'),
      true
    )
    assert.equal(page.container.querySelector('a[href="/wallet"]'), null)
    assert.equal(page.container.querySelector('a[href="/support"]'), null)

    topup.resolve({ data: { success: true, data: emptyTopupInfo } })
    await act(flushEffects)
    await unmountPage(page)
  })

  test('offers the administrator request path when payment is unavailable', async () => {
    for (const response of [
      { data: { success: false, message: 'offline' } },
      { data: { success: true, data: emptyTopupInfo } },
    ]) {
      const page = await renderPage(Promise.resolve(response))
      const expected = response.data.success
        ? 'Online payment is temporarily unavailable. You can submit an administrator unlock request instead.'
        : 'Payment availability could not be verified. You can submit an administrator unlock request instead.'
      assert.equal(page.container.textContent?.includes(expected), true)
      assert.equal(
        page.container.textContent?.includes('Choose how to unlock access'),
        true
      )
      assert.ok(page.container.querySelector('button'))
      assert.equal(page.container.querySelector('a[href="/wallet"]'), null)
      await unmountPage(page)
    }
  })

  test('shows wallet activation and optional challenges only from confirmed live capabilities', async () => {
    const page = await renderPage(
      Promise.resolve({
        data: {
          success: true,
          data: {
            ...emptyTopupInfo,
            enable_online_topup: true,
            pay_methods: [{ name: 'Card', type: 'card' }],
          },
        },
      }),
      true
    )
    await act(flushEffects)

    assert.ok(page.container.querySelector('a[href="/wallet"]'))
    assert.equal(
      page.container.textContent?.includes(
        'Choose either automatic activation after adding funds or an administrator unlock request.'
      ),
      true
    )
    assert.equal(
      page.container.textContent?.includes('Optional open-source challenges'),
      true
    )
    assert.equal(
      page.container.textContent?.includes(
        'Contributions can earn account credit, but they do not activate access.'
      ),
      true
    )
    assert.equal(
      page.gets.some((url) => url.startsWith('/api/open-source-bounties?')),
      true
    )
    await unmountPage(page)
  })

  test('keeps unavailable optional probes inline and does not retry them', async () => {
    const page = await renderPage(
      Promise.resolve({ data: { success: true, data: emptyTopupInfo } }),
      true,
      new Error('Not Found')
    )
    await act(flushEffects)

    const bountyCalls = page.gets.filter((url) =>
      url.startsWith('/api/open-source-bounties?')
    )
    assert.equal(bountyCalls.length, 1)
    assert.equal(
      page.container.textContent?.includes(
        'Challenges are temporarily unavailable.'
      ),
      true
    )

    const topupConfig = page.getConfigs.find(
      (_, index) => page.gets[index] === '/api/user/topup/info'
    )
    assert.equal(topupConfig?.skipBusinessError, true)
    assert.equal(topupConfig?.skipErrorHandler, true)

    const bountyConfig = page.getConfigs.find((_, index) =>
      page.gets[index].startsWith('/api/open-source-bounties?')
    )
    assert.equal(bountyConfig?.skipBusinessError, true)
    assert.equal(bountyConfig?.skipErrorHandler, true)
    await unmountPage(page)
  })
})
