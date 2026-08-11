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
  'HTMLInputElement',
  'SVGElement',
  'Node',
  'Element',
  'Event',
  'CustomEvent',
  'MutationObserver',
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
const { AssistantPlanTool } = await import('./assistant-plan-tool')

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

async function flushQueries() {
  await new Promise((resolve) => setTimeout(resolve, 20))
}

const topupFixture = {
  success: true,
  data: {
    developer_access_granted: true,
    activation_required: false,
    payment_available: true,
    enable_online_topup: true,
    enable_stripe_topup: false,
    pay_methods: [{ name: 'Card', type: 'epay' }],
    min_topup: 10,
    stripe_min_topup: 10,
    amount_options: [100],
    discount: { 100: 0.8 },
  },
}

const plansFixture = {
  success: true,
  data: [
    {
      plan: {
        id: 1,
        title: 'Starter',
        price_amount: 8,
        currency: 'USD',
        duration_unit: 'month',
        duration_value: 1,
        quota_reset_period: 'monthly',
        enabled: true,
        sort_order: 1,
        allow_balance_pay: true,
        allow_wallet_overflow: true,
        max_purchase_per_user: 0,
        total_amount: 5_000_000,
      },
    },
    {
      plan: {
        id: 2,
        title: 'Pro',
        price_amount: 15,
        currency: 'USD',
        duration_unit: 'month',
        duration_value: 1,
        quota_reset_period: 'monthly',
        enabled: true,
        sort_order: 2,
        allow_balance_pay: true,
        allow_wallet_overflow: true,
        max_purchase_per_user: 0,
        total_amount: 15_000_000,
      },
    },
  ],
}

async function renderTool(developerAccessGranted: boolean) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const rootRoute = createRootRoute({
    component: () => (
      <QueryClientProvider client={queryClient}>
        <I18nextProvider i18n={i18n}>
          <AssistantPlanTool developerAccessGranted={developerAccessGranted} />
        </I18nextProvider>
      </QueryClientProvider>
    ),
  })
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: () => null,
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute]),
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)

  await act(async () => {
    root.render(<RouterProvider router={router} />)
    await flushQueries()
  })
  await act(flushQueries)
  return { container, queryClient, root }
}

function findRetryButton(alertTitle: string): HTMLButtonElement {
  const title = [
    ...document.querySelectorAll<HTMLElement>('[data-slot="alert-title"]'),
  ].find((candidate) => candidate.textContent?.includes(alertTitle))
  const button = title
    ?.closest('[data-slot="alert"]')
    ?.querySelector<HTMLButtonElement>('button')
  assert.ok(button, `Could not find retry button for ${alertTitle}`)
  return button
}

async function unmount(rendered: Awaited<ReturnType<typeof renderTool>>) {
  await act(async () => rendered.root.unmount())
  rendered.queryClient.clear()
  rendered.container.remove()
}

afterEach(() => {
  api.get = originalGet
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('AssistantPlanTool', () => {
  test('formats plan prices and discounts with internal Chinese locale codes', async () => {
    api.get = (async (url: string) => {
      if (url === '/api/subscription/plans') return { data: plansFixture }
      if (url === '/api/user/topup/info') return { data: topupFixture }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    await i18n.changeLanguage('zhTW')
    const rendered = await renderTool(true)
    try {
      assert.match(rendered.container.textContent ?? '', /US\$8\.00/)
      assert.match(rendered.container.textContent ?? '', /save 20%/)
    } finally {
      await unmount(rendered)
      await i18n.changeLanguage('en')
    }
  })

  test('shows live plans and top-up discounts to L0 without enabling write actions', async () => {
    let topupCalls = 0
    let planCalls = 0
    api.get = (async (url: string) => {
      if (url === '/api/user/topup/info') {
        topupCalls += 1
        return {
          data: {
            success: true,
            data: {
              developer_access_granted: false,
              activation_required: true,
              payment_available: true,
              enable_online_topup: true,
              enable_stripe_topup: false,
              pay_methods: [{ name: 'Card', type: 'epay' }],
              min_topup: 10,
              stripe_min_topup: 10,
              amount_options: [100],
              discount: { 100: 0.8 },
            },
          },
        }
      }
      if (url === '/api/subscription/plans') {
        planCalls += 1
        return { data: plansFixture }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    const rendered = await renderTool(false)

    assert.equal(topupCalls, 1)
    assert.equal(planCalls, 1)
    assert.match(rendered.container.textContent ?? '', /Pro/)
    assert.match(rendered.container.textContent ?? '', /Closest fit/)
    assert.match(
      rendered.container.textContent ?? '',
      /Best current top-up discounts/
    )
    assert.match(rendered.container.textContent ?? '', /save 20%/)
    assert.match(rendered.container.textContent ?? '', /Add funds/)
    assert.ok(
      rendered.container.querySelector<HTMLInputElement>(
        '#assistant-expected-credit'
      )
    )

    await unmount(rendered)
  })

  test('keeps discounts visible while plan loading fails and explains the recovered recommendation', async () => {
    let planCalls = 0
    api.get = (async (url: string) => {
      if (url === '/api/user/topup/info') return { data: topupFixture }
      if (url === '/api/subscription/plans') {
        planCalls += 1
        if (planCalls === 1) throw new Error('plans offline')
        return { data: plansFixture }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    const rendered = await renderTool(true)
    assert.match(
      rendered.container.textContent ?? '',
      /Unable to load live subscription plans/
    )
    assert.match(rendered.container.textContent ?? '', /save 20%/)

    await act(async () => {
      findRetryButton('Unable to load live subscription plans').click()
      await flushQueries()
    })
    await act(flushQueries)

    assert.match(rendered.container.textContent ?? '', /Pro/)
    assert.match(rendered.container.textContent ?? '', /Closest fit/)
    assert.match(
      rendered.container.textContent ?? '',
      /smallest available capacity that covers your \$20 USD monthly estimate/
    )
    assert.equal(planCalls, 2)

    const expectedInput = rendered.container.querySelector<HTMLInputElement>(
      '#assistant-expected-credit'
    )
    assert.ok(expectedInput)
    await act(async () => {
      const setValue = Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        'value'
      )?.set
      assert.ok(setValue)
      setValue.call(expectedInput, '40')
      expectedInput.dispatchEvent(new Event('input', { bubbles: true }))
      await flushQueries()
    })
    assert.match(
      rendered.container.textContent ?? '',
      /No plan fully covers your \$40 USD monthly estimate/
    )

    await unmount(rendered)
  })

  test('keeps plan advice visible and recovers top-up discounts independently', async () => {
    let topupCalls = 0
    api.get = (async (url: string) => {
      if (url === '/api/subscription/plans') return { data: plansFixture }
      if (url === '/api/user/topup/info') {
        topupCalls += 1
        if (topupCalls === 1) throw new Error('discounts offline')
        return { data: topupFixture }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    const rendered = await renderTool(true)
    assert.match(rendered.container.textContent ?? '', /Closest fit/)
    assert.match(
      rendered.container.textContent ?? '',
      /Unable to load current top-up discounts/
    )

    await act(async () => {
      findRetryButton('Unable to load current top-up discounts').click()
      await flushQueries()
    })
    await act(flushQueries)

    assert.match(rendered.container.textContent ?? '', /save 20%/)
    assert.equal(topupCalls, 2)

    await unmount(rendered)
  })
})
