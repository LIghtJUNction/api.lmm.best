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
  'HTMLFormElement',
  'HTMLInputElement',
  'HTMLTextAreaElement',
  'SVGElement',
  'Node',
  'Element',
  'Event',
  'MouseEvent',
  'PointerEvent',
  'FocusEvent',
  'CustomEvent',
  'FormData',
  'File',
  'FileReader',
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
const { requestAssistantOpen } = await import('./assistant-events')
const { AssistantLauncher } = await import('./assistant-launcher')
const { AssistantPanel } = await import('./assistant-panel')

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

const assistantStatus = {
  enabled: true,
  model: 'deepseek-v4-flash',
  developer_access_granted: true,
  funding: {
    mode: 'super_administrator' as const,
  },
}

async function flushEffects() {
  await new Promise((resolve) => setTimeout(resolve, 25))
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

async function renderPanel(
  initialPreset?: 'api-key' | 'models' | 'onboarding' | 'plan'
) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const rootRoute = createRootRoute({
    component: () => (
      <QueryClientProvider client={queryClient}>
        <I18nextProvider i18n={i18n}>
          <AssistantPanel
            open
            initialPreset={initialPreset}
            onOpenChange={() => {}}
          />
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
    await flushEffects()
  })
  await act(flushEffects)
  return { container, queryClient, root }
}

async function renderLauncher() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const rootRoute = createRootRoute({
    component: () => (
      <QueryClientProvider client={queryClient}>
        <I18nextProvider i18n={i18n}>
          <AssistantLauncher />
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

afterEach(() => {
  api.get = originalGet
  api.post = originalPost
  window.localStorage.clear()
  window.sessionStorage.clear()
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('AssistantPanel', () => {
  test('keeps the conversation when the floating assistant is closed and reopened', async () => {
    api.get = (async (url: string) => {
      if (url === '/api/status') {
        return {
          data: {
            success: true,
            data: { assistant: { enabled: true } },
          },
        }
      }
      assert.equal(url, '/api/assistant/status')
      return { data: { success: true, data: assistantStatus } }
    }) as typeof api.get

    const rendered = await renderLauncher()
    try {
      const launcherButton = document.querySelector<HTMLButtonElement>(
        'button[aria-label="Open AI assistant"]'
      )
      assert.ok(launcherButton)
      assert.equal(launcherButton.getAttribute('aria-haspopup'), 'dialog')
      assert.equal(launcherButton.getAttribute('aria-expanded'), 'false')
      assert.equal(launcherButton.hasAttribute('aria-controls'), false)
      await act(async () => {
        launcherButton.click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () => document.body.textContent?.includes('How can I help?') === true,
          'Assistant panel did not open'
        )
      )
      assert.equal(launcherButton.getAttribute('aria-expanded'), 'true')
      assert.equal(
        launcherButton.getAttribute('aria-controls'),
        'ai-assistant-panel'
      )
      assert.ok(document.querySelector('#ai-assistant-panel'))
      await act(async () =>
        waitForCondition(
          () =>
            document.body.textContent?.includes(
              'Which option is the best value?'
            ) === true,
          'L1 assistant presets did not render'
        )
      )

      await act(async () => {
        findButton('Which option is the best value?').click()
        await flushEffects()
      })
      assert.match(
        document.body.textContent ?? '',
        /Choose by workload rather than list price\./
      )

      const closeButton = document.querySelector<HTMLButtonElement>(
        '[data-slot="sheet-close"]'
      )
      assert.ok(closeButton)
      await act(async () => {
        closeButton.click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () => document.querySelector('[data-slot="sheet-content"]') === null,
          'Assistant panel did not close'
        )
      )
      assert.equal(launcherButton.getAttribute('aria-expanded'), 'false')

      await act(async () => {
        launcherButton.click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () =>
            document.body.textContent?.includes(
              'Choose by workload rather than list price.'
            ) === true,
          'Assistant conversation was not restored'
        )
      )
      assert.equal(
        (document.body.textContent ?? '').match(
          /Which option is the best value\?/g
        )?.length,
        1
      )
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('syncs queued questions into an already-open assistant input', async () => {
    api.get = (async (url: string) => {
      if (url === '/api/status') {
        return {
          data: {
            success: true,
            data: { assistant: { enabled: true } },
          },
        }
      }
      assert.equal(url, '/api/assistant/status')
      return { data: { success: true, data: assistantStatus } }
    }) as typeof api.get

    const rendered = await renderLauncher()
    try {
      const launcherButton = document.querySelector<HTMLButtonElement>(
        'button[aria-label="Open AI assistant"]'
      )
      assert.ok(launcherButton)
      await act(async () => {
        launcherButton.click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () => document.querySelector('textarea') !== null,
          'Assistant input did not render'
        )
      )

      const textarea = document.querySelector<HTMLTextAreaElement>('textarea')
      assert.ok(textarea)
      const question = 'How do I set up Claude Code or CC Switch?'

      await act(async () => {
        requestAssistantOpen(undefined, question)
        await flushEffects()
      })
      assert.equal(textarea.value, question)

      await setTextareaValue(textarea, 'draft that should be replaced')
      await act(async () => {
        requestAssistantOpen(undefined, question)
        await flushEffects()
      })
      assert.equal(textarea.value, question)
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('appends guided presets without replacing the current conversation', async () => {
    api.get = (async (url: string) => {
      assert.equal(url, '/api/assistant/status')
      return { data: { success: true, data: assistantStatus } }
    }) as typeof api.get

    const rendered = await renderPanel('api-key')
    try {
      assert.match(
        document.body.textContent ?? '',
        /What are my Base URL, model ID, and API key\?/
      )

      await act(async () => {
        requestAssistantOpen('plan')
        await flushEffects()
      })

      assert.match(
        document.body.textContent ?? '',
        /What are my Base URL, model ID, and API key\?/
      )
      assert.match(
        document.body.textContent ?? '',
        /Which option is the best value\?/
      )
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('keeps L0 guidance useful without exposing account or payment actions', async () => {
    api.get = (async (url: string) => {
      if (url === '/api/assistant/status') {
        return {
          data: {
            success: true,
            data: { ...assistantStatus, developer_access_granted: false },
          },
        }
      }
      if (url === '/api/user/developer-access/request') {
        return { data: { success: true, data: null } }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    const rendered = await renderPanel('onboarding')
    try {
      await act(async () =>
        waitForCondition(
          () => document.querySelector('textarea') !== null,
          'L0 access request did not render'
        )
      )
      assert.match(
        document.body.textContent ?? '',
        /Ask an administrator to raise my access level/
      )
      assert.doesNotMatch(
        document.body.textContent ?? '',
        /What are my Base URL, model ID, and API key\?/
      )
      assert.equal(document.querySelector('a[href="/wallet"]'), null)
      assert.doesNotMatch(
        document.body.textContent ?? '',
        /Your wallet is charged/
      )

      await act(async () => {
        findButton('Clear conversation').click()
        await flushEffects()
      })
      assert.ok(findButton('Ask an administrator to raise my access level'))
      assert.ok(findButton('Which option is the best value?'))
      assert.ok(findButton('How is request cost calculated?'))
      assert.ok(findButton('What can I do while access is under review?'))
      assert.ok(findButton('How do I set up Claude Code or CC Switch?'))

      await act(async () => {
        findButton('Which option is the best value?').click()
        await flushEffects()
      })
      assert.match(
        document.body.textContent ?? '',
        /prepare an L1 recommendation for your confirmation/
      )
      assert.equal(document.querySelector('a[href="/wallet"]'), null)
      assert.throws(() => findButton('Compare live plans'))
      assert.ok(findButton('Unlock L1 access'))
      assert.equal(document.querySelector('a[href="/wallet"]'), null)
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('does not mistake a failed access check for L0 or expose presets', async () => {
    api.get = (async (url: string) => {
      assert.equal(url, '/api/assistant/status')
      throw new Error('status unavailable')
    }) as typeof api.get

    const rendered = await renderPanel()
    try {
      await act(async () =>
        waitForCondition(
          () =>
            document.body.textContent?.includes(
              'Unable to verify account access'
            ) === true,
          'Assistant did not render the access error'
        )
      )
      assert.doesNotMatch(
        document.body.textContent ?? '',
        /Ask an administrator to raise my access level/
      )
      assert.doesNotMatch(
        document.body.textContent ?? '',
        /Which option is the best value\?/
      )
      assert.ok(findButton('Retry'))
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('shows the signed-in model IDs inside the assistant', async () => {
    api.get = (async (url: string) => {
      if (url === '/api/assistant/status') {
        return { data: { success: true, data: assistantStatus } }
      }
      if (url === '/api/user/models') {
        return {
          data: {
            success: true,
            data: ['claude-3-7-sonnet', 'deepseek-v4-flash'],
          },
        }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get

    const rendered = await renderPanel('models')
    try {
      await act(async () => {
        findButton('View all currently available models').click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () =>
            document.body.textContent?.includes('claude-3-7-sonnet') === true,
          'Assistant model IDs did not render'
        )
      )
      assert.match(document.body.textContent ?? '', /deepseek-v4-flash/)
      assert.doesNotMatch(
        document.body.textContent ?? '',
        /Default assistant model/
      )
      assert.ok(document.querySelector('button[aria-label="Copy model names"]'))
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('shows that the super administrator funds assistant usage', async () => {
    api.get = (async (url: string) => {
      assert.equal(url, '/api/assistant/status')
      return { data: { success: true, data: assistantStatus } }
    }) as typeof api.get

    const rendered = await renderPanel()
    try {
      assert.match(
        document.body.textContent ?? '',
        /Funded by the super administrator/
      )
      assert.match(
        document.body.textContent ?? '',
        /charged to the super administrator account, not your wallet/
      )
      assert.doesNotMatch(document.body.textContent ?? '', /Weekly included/)
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('opens an explicit confirmation for an AI L1 recommendation', async () => {
    let submittedRecommendation: unknown
    api.get = (async (url: string) => {
      if (url === '/api/assistant/status') {
        return {
          data: {
            success: true,
            data: { ...assistantStatus, developer_access_granted: false },
          },
        }
      }
      if (url === '/api/user/developer-access/request') {
        return { data: { success: true, data: null } }
      }
      throw new Error(`Unexpected GET ${url}`)
    }) as typeof api.get
    api.post = (async (url: string, data: unknown) => {
      if (url === '/api/assistant/chat') {
        return {
          data: {
            choices: [
              {
                message: {
                  content: 'I have enough detail to recommend L1 access.',
                },
              },
            ],
            lmm_assistant_action: {
              type: 'l1_recommendation',
              user_statement: 'I will connect Claude Code for private work.',
              recommendation:
                'Recommend L1 because the user identified a specific client and purpose.',
              confirmation_token: 'assistant-confirmation-token',
            },
          },
          headers: { 'x-lmm-assistant-intent': 'onboarding' },
        }
      }
      assert.equal(url, '/api/user/developer-access/request')
      submittedRecommendation = data
      return {
        data: {
          success: true,
          data: {
            id: 11,
            status: 'pending',
            reason: 'I will connect Claude Code for private work.',
            source: 'assistant_recommendation',
            ai_recommendation:
              'Recommend L1 because the user identified a specific client and purpose.',
            admin_note: '',
            created_at: 1_786_400_000,
            reviewed_at: 0,
          },
        },
      }
    }) as typeof api.post

    const rendered = await renderPanel()
    try {
      const textarea = document.querySelector<HTMLTextAreaElement>(
        'textarea[placeholder="Write a short explanation of what you want to build or why you need L1 access."]'
      )
      assert.ok(textarea)
      await setTextareaValue(
        textarea,
        'I want Claude Code access for my private project.'
      )
      const submit = document.querySelector<HTMLButtonElement>(
        'button[aria-label="Submit"]'
      )
      assert.ok(submit)
      await act(async () => {
        submit.click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () =>
            document.body.textContent?.includes('Confirm AI recommendation') ===
            true,
          'AI recommendation confirmation did not render'
        )
      )
      assert.match(
        document.body.textContent ?? '',
        /I will connect Claude Code for private work\./
      )

      await act(async () => {
        findButton('Confirm and send to administrator').click()
        await flushEffects()
      })
      await act(async () =>
        waitForCondition(
          () => submittedRecommendation !== undefined,
          'Confirmed recommendation was not submitted'
        )
      )
      assert.deepEqual(submittedRecommendation, {
        reason: 'I will connect Claude Code for private work.',
        ai_recommendation:
          'Recommend L1 because the user identified a specific client and purpose.',
        confirmation_token: 'assistant-confirmation-token',
        confirmed: true,
      })
    } finally {
      await act(async () => rendered.root.unmount())
      rendered.queryClient.clear()
    }
  })

  test('retries the exact failed conversation without duplicating the user message', async () => {
    const posted: unknown[] = []
    api.get = (async (url: string) => {
      assert.equal(url, '/api/assistant/status')
      return { data: { success: true, data: assistantStatus } }
    }) as typeof api.get
    api.post = (async (url: string, data: unknown) => {
      assert.equal(url, '/api/assistant/chat')
      posted.push(data)
      if (posted.length === 1) throw new Error('assistant offline')
      return {
        data: {
          choices: [
            { message: { content: 'Use the verified Windows guide.' } },
          ],
        },
        headers: { 'x-lmm-assistant-intent': 'client_setup' },
      }
    }) as typeof api.post

    const rendered = await renderPanel()
    const textarea = document.querySelector<HTMLTextAreaElement>(
      'textarea[placeholder="Ask about plans, setup, keys, or costs..."]'
    )
    assert.ok(textarea)
    assert.match(
      document.body.textContent ?? '',
      /AI customer-service token usage is charged to the super administrator account, not your wallet\./
    )
    await setTextareaValue(textarea, 'How do I configure Claude Code?')
    const submit = document.querySelector<HTMLButtonElement>(
      'button[aria-label="Submit"]'
    )
    assert.ok(submit)

    await act(async () => {
      submit.click()
      await flushEffects()
    })
    await act(async () =>
      waitForCondition(
        () => document.body.textContent?.includes('Contact support') === true,
        'Assistant error actions did not render'
      )
    )
    assert.match(
      document.body.textContent ?? '',
      /The AI assistant could not answer right now/
    )
    assert.equal(posted.length, 1)

    await act(async () => {
      findButton('Retry').click()
      await flushEffects()
    })
    await act(async () =>
      waitForCondition(
        () =>
          document.body.textContent?.includes(
            'Use the verified Windows guide.'
          ) === true,
        'Retried assistant answer did not render'
      )
    )

    assert.equal(posted.length, 2)
    assert.deepEqual(posted[1], posted[0])
    assert.doesNotMatch(
      document.body.textContent ?? '',
      /The AI assistant could not answer right now/
    )
    assert.equal(
      (document.body.textContent ?? '').match(
        /How do I configure Claude Code\?/g
      )?.length,
      1
    )

    await act(async () => rendered.root.unmount())
    rendered.queryClient.clear()
  })
})
