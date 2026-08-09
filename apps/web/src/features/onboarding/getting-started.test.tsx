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

const user = {
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
  const emptyRoutes = [
    '/wallet',
    '/support',
    '/keys',
    '/playground',
    '/dashboard',
  ].map((path) =>
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
  bountyCapability = false
) {
  const gets: string[] = []
  api.get = (async (url) => {
    gets.push(url)
    if (url === '/api/user/self') {
      return { data: { success: true, data: user } }
    }
    if (url === '/api/user/topup/info') return topupResponse
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
      return {
        data: {
          success: true,
          data: { items: [], total: 0, page: 1, page_size: 50 },
        },
      }
    }
    return { data: { success: true, data: [] } }
  }) as typeof api.get
  useAuthStore.getState().auth.setUser(user)

  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
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
  return { container, root, queryClient, gets }
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
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('getting started payment availability', () => {
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

  test('offers support only when availability fails or is confirmed empty', async () => {
    for (const response of [
      { data: { success: false, message: 'offline' } },
      { data: { success: true, data: emptyTopupInfo } },
    ]) {
      const page = await renderPage(Promise.resolve(response))
      const expected = response.data.success
        ? 'Online payment is temporarily unavailable. Contact support before attempting to add funds.'
        : 'Payment availability could not be verified. Contact support before attempting to add funds.'
      assert.equal(page.container.textContent?.includes(expected), true)
      assert.ok(page.container.querySelector('a[href="/support"]'))
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
        'Any successful external top-up activates access.'
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
})
