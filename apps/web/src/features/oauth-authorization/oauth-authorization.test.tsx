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
import assert from 'node:assert/strict'
import { after, afterEach, describe, test } from 'node:test'

import { Window } from 'happy-dom'

const domWindow = new Window({ url: 'https://dashboard.example.com/' })
for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'HTMLButtonElement',
  'HTMLInputElement',
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
const { createInstance } = await import('i18next')
const { I18nextProvider, initReactI18next } = await import('react-i18next')
const { QueryClient, QueryClientProvider } = await import(
  '@tanstack/react-query'
)
const {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} = await import('@tanstack/react-router')
const { api } = await import('@/lib/api')
const { useAuthStore } = await import('@/stores/auth-store')
const { AuthorizationConsent } = await import('./authorization-consent')
const { DeviceAuthorization } = await import('./device-authorization')

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

async function flushEffects() {
  await new Promise((resolve) => setTimeout(resolve, 100))
}

async function waitForQuery(
  queryClient: InstanceType<typeof QueryClient>,
  queryKey: readonly unknown[]
) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const state = queryClient.getQueryState(queryKey)
    if (state?.status === 'success') {
      await act(flushEffects)
      return
    }
    if (state?.status === 'error') throw state.error
    await act(flushEffects)
  }
  assert.fail(`query did not settle: ${JSON.stringify(queryClient.getQueryState(queryKey))}`)
}

async function renderNode(node: React.ReactNode) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  const rootRoute = createRootRoute({ component: () => node })
  const router = createRouter({
    routeTree: rootRoute,
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  await router.load()

  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => {
    root.render(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </I18nextProvider>
    )
    await flushEffects()
  })
  return { container, root, queryClient }
}

afterEach(() => {
  api.get = originalGet
  api.post = originalPost
  useAuthStore.getState().auth.reset('complete')
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('OAuth authorization consent', () => {
  test('shows the client, requested scopes, account, and local callback', async () => {
    useAuthStore.setState((state) => ({
      auth: {
        ...state.auth,
        user: { id: 7, username: 'forge-user', role: 1 },
        accessToken: 'browser-access-token',
      },
    }))
    api.get = (async () => ({
      data: {
        success: true,
        data: {
          client_id: 'lmm-api-rs',
          client_name: 'lmm-api-rs',
          redirect_uri: 'http://127.0.0.1:49152/oauth/callback',
          scopes: ['api_keys:list', 'cc_switch:import'],
          expires_at: new Date(Date.now() + 60_000).toISOString(),
        },
      },
    })) as typeof api.get

    const rendered = await renderNode(
      <AuthorizationConsent request='one-time-request' />
    )
    await waitForQuery(rendered.queryClient, [
      'oauth-authorization',
      'one-time-request',
    ])

    assert.match(rendered.container.textContent ?? '', /lmm-api-rs/)
    assert.match(rendered.container.textContent ?? '', /forge-user/)
    assert.match(rendered.container.textContent ?? '', /View your API Key list/)
    assert.match(rendered.container.textContent ?? '', /Import into CC Switch/)
    assert.match(rendered.container.textContent ?? '', /127\.0\.0\.1:49152/)
    assert.equal(
      [...rendered.container.querySelectorAll('button')].some(
        (button) => button.textContent?.trim() === 'Allow access'
      ),
      true
    )

    await act(async () => rendered.root.unmount())
    rendered.queryClient.clear()
  })
})

describe('OAuth device authorization', () => {
  test('normalizes a prefilled code, submits once, and shows completion', async () => {
    useAuthStore.setState((state) => ({
      auth: {
        ...state.auth,
        user: { id: 8, username: 'device-user', role: 1 },
        accessToken: 'browser-access-token',
      },
    }))
    const posts: Array<{ url: string; body: unknown }> = []
    api.post = (async (url, body) => {
      posts.push({ url, body })
      return { data: { success: true, data: { approved: true } } }
    }) as typeof api.post

    const rendered = await renderNode(
      <DeviceAuthorization userCode='abcd efgh' />
    )
    const input = rendered.container.querySelector<HTMLInputElement>(
      '#oauth-device-code'
    )
    assert.equal(input?.value, 'ABCD-EFGH')

    const connect = [
      ...rendered.container.querySelectorAll<HTMLButtonElement>('button'),
    ].find((button) => button.textContent?.trim() === 'Connect device')
    assert.ok(connect)

    await act(async () => {
      connect.click()
      await flushEffects()
    })

    assert.deepEqual(posts, [
      {
        url: '/api/oauth/device',
        body: { user_code: 'ABCD-EFGH', approve: true },
      },
    ])
    assert.match(rendered.container.textContent ?? '', /Device connected/)
    assert.match(
      rendered.container.textContent ?? '',
      /finish signing in automatically/
    )

    await act(async () => rendered.root.unmount())
    rendered.queryClient.clear()
  })
})
