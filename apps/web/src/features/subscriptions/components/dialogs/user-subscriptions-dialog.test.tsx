/*
Copyright (C) 2026 LIghtJUNction

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

import type {
  ApiResponse,
  PlanRecord,
  UserSubscriptionRecord,
} from '../../types'

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
const { toast } = await import('sonner')
const { api } = await import('@/lib/api')
const { UserSubscriptionsDialog } = await import('./user-subscriptions-dialog')

const originalGet = api.get
const originalToastError = toast.error
const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

const i18n = createInstance()
await i18n.use(initReactI18next).init({
  lng: 'en',
  resources: { en: { translation: {} } },
})

type Deferred<T> = {
  promise: Promise<T>
  resolve: (value: T | PromiseLike<T>) => void
  reject: (reason?: unknown) => void
}

type PendingRequest = {
  url: string
  response: { promise: Promise<unknown> }
}

function deferred<T>(): Deferred<T> {
  let resolve!: Deferred<T>['resolve']
  let reject!: Deferred<T>['reject']
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

function installDeferredTransport(requests: PendingRequest[]) {
  let requestIndex = 0
  api.get = (async (url: string) => {
    const request = requests[requestIndex++]
    assert.ok(request, `Unexpected GET request: ${url}`)
    assert.equal(url, request.url)
    return { data: await request.response.promise }
  }) as typeof api.get
}

function plansResponse(id: number, title: string): ApiResponse<PlanRecord[]> {
  return {
    success: true,
    data: [
      {
        plan: { id, title } as PlanRecord['plan'],
      },
    ],
  }
}

function subscriptionsResponse(
  id: number,
  userId: number,
  planId: number
): ApiResponse<UserSubscriptionRecord[]> {
  return {
    success: true,
    data: [
      {
        subscription: {
          id,
          user_id: userId,
          plan_id: planId,
          status: 'active',
          source: 'test',
          start_time: 1,
          end_time: 4_000_000_000,
          amount_total: 100,
          amount_used: 0,
        },
      },
    ],
  }
}

async function flush() {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

function dialogElement(
  open: boolean,
  user: { id: number; username?: string } | null
) {
  return (
    <I18nextProvider i18n={i18n}>
      <UserSubscriptionsDialog
        open={open}
        user={user}
        onOpenChange={() => undefined}
      />
    </I18nextProvider>
  )
}

async function renderDialog(
  open: boolean,
  user: { id: number; username?: string } | null
) {
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => {
    root.render(dialogElement(open, user))
    await flush()
  })
  return { container, root }
}

async function rerenderDialog(
  root: ReturnType<typeof createRoot>,
  open: boolean,
  user: { id: number; username?: string } | null
) {
  await act(async () => {
    root.render(dialogElement(open, user))
    await flush()
  })
}

async function unmountDialog(
  rendered: Awaited<ReturnType<typeof renderDialog>>
) {
  await act(async () => rendered.root.unmount())
  rendered.container.remove()
}

function dialogText() {
  return document.body.textContent ?? ''
}

afterEach(() => {
  api.get = originalGet
  toast.error = originalToastError
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('UserSubscriptionsDialog request isolation', () => {
  test('keeps the latest user when the earlier load resolves last', async () => {
    const plansA = deferred<ApiResponse<PlanRecord[]>>()
    const subsA = deferred<ApiResponse<UserSubscriptionRecord[]>>()
    const plansB = deferred<ApiResponse<PlanRecord[]>>()
    const subsB = deferred<ApiResponse<UserSubscriptionRecord[]>>()
    installDeferredTransport([
      {
        url: '/api/subscription/admin/plans',
        response: plansA,
      },
      {
        url: '/api/subscription/admin/users/1/subscriptions',
        response: subsA,
      },
      {
        url: '/api/subscription/admin/plans',
        response: plansB,
      },
      {
        url: '/api/subscription/admin/users/2/subscriptions',
        response: subsB,
      },
    ])

    const rendered = await renderDialog(true, { id: 1, username: 'A' })
    try {
      await rerenderDialog(rendered.root, true, { id: 2, username: 'B' })
      assert.match(dialogText(), /Loading\.\.\./)
      assert.doesNotMatch(dialogText(), /101/)

      await act(async () => {
        plansB.resolve(plansResponse(20, 'B plan'))
        subsB.resolve(subscriptionsResponse(202, 2, 20))
        await flush()
      })
      assert.match(dialogText(), /B plan/)
      assert.match(dialogText(), /202/)
      assert.doesNotMatch(dialogText(), /A plan/)
      assert.doesNotMatch(dialogText(), /101/)
      assert.doesNotMatch(dialogText(), /Loading\.\.\./)

      await act(async () => {
        plansA.resolve(plansResponse(10, 'A plan'))
        subsA.resolve(subscriptionsResponse(101, 1, 10))
        await flush()
      })
      assert.match(dialogText(), /B plan/)
      assert.match(dialogText(), /202/)
      assert.doesNotMatch(dialogText(), /A plan/)
      assert.doesNotMatch(dialogText(), /101/)
    } finally {
      await unmountDialog(rendered)
    }
  })

  test('ignores a stale partial failure, error, and finally state', async () => {
    const plansA = deferred<ApiResponse<PlanRecord[]>>()
    const subsA = deferred<ApiResponse<UserSubscriptionRecord[]>>()
    const plansB = deferred<ApiResponse<PlanRecord[]>>()
    const subsB = deferred<ApiResponse<UserSubscriptionRecord[]>>()
    installDeferredTransport([
      {
        url: '/api/subscription/admin/plans',
        response: plansA,
      },
      {
        url: '/api/subscription/admin/users/1/subscriptions',
        response: subsA,
      },
      {
        url: '/api/subscription/admin/plans',
        response: plansB,
      },
      {
        url: '/api/subscription/admin/users/2/subscriptions',
        response: subsB,
      },
    ])
    const errors: string[] = []
    toast.error = ((message: unknown) => {
      errors.push(String(message))
      return 1
    }) as typeof toast.error

    const rendered = await renderDialog(true, { id: 1, username: 'A' })
    try {
      await rerenderDialog(rendered.root, true, { id: 2, username: 'B' })

      await act(async () => {
        plansA.reject(new Error('A plans failed'))
        await flush()
      })
      assert.match(dialogText(), /Loading\.\.\./)
      assert.deepEqual(errors, [])

      await act(async () => {
        subsA.resolve(subscriptionsResponse(101, 1, 10))
        await flush()
      })
      assert.match(dialogText(), /Loading\.\.\./)
      assert.deepEqual(errors, [])

      await act(async () => {
        plansB.resolve(plansResponse(20, 'B plan'))
        subsB.resolve(subscriptionsResponse(202, 2, 20))
        await flush()
      })
      assert.doesNotMatch(dialogText(), /Loading\.\.\./)
      assert.match(dialogText(), /B plan/)
      assert.match(dialogText(), /202/)
      assert.deepEqual(errors, [])
    } finally {
      await unmountDialog(rendered)
    }
  })

  test('invalidates responses from a closed dialog before reopening it', async () => {
    const oldPlans = deferred<ApiResponse<PlanRecord[]>>()
    const oldSubs = deferred<ApiResponse<UserSubscriptionRecord[]>>()
    const reopenedPlans = deferred<ApiResponse<PlanRecord[]>>()
    const reopenedSubs = deferred<ApiResponse<UserSubscriptionRecord[]>>()
    installDeferredTransport([
      {
        url: '/api/subscription/admin/plans',
        response: oldPlans,
      },
      {
        url: '/api/subscription/admin/users/1/subscriptions',
        response: oldSubs,
      },
      {
        url: '/api/subscription/admin/plans',
        response: reopenedPlans,
      },
      {
        url: '/api/subscription/admin/users/1/subscriptions',
        response: reopenedSubs,
      },
    ])

    const rendered = await renderDialog(true, { id: 1, username: 'A' })
    try {
      await rerenderDialog(rendered.root, false, { id: 1, username: 'A' })
      await rerenderDialog(rendered.root, true, {
        id: 1,
        username: 'A reopened',
      })

      await act(async () => {
        reopenedPlans.resolve(plansResponse(20, 'Reopened plan'))
        reopenedSubs.resolve(subscriptionsResponse(202, 1, 20))
        await flush()
      })
      assert.match(dialogText(), /Reopened plan/)
      assert.match(dialogText(), /202/)
      assert.doesNotMatch(dialogText(), /Old plan/)
      assert.doesNotMatch(dialogText(), /101/)

      await act(async () => {
        oldPlans.resolve(plansResponse(10, 'Old plan'))
        oldSubs.resolve(subscriptionsResponse(101, 1, 10))
        await flush()
      })
      assert.match(dialogText(), /Reopened plan/)
      assert.match(dialogText(), /202/)
      assert.doesNotMatch(dialogText(), /Old plan/)
      assert.doesNotMatch(dialogText(), /101/)
    } finally {
      await unmountDialog(rendered)
    }
  })
})
