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
import { after, describe, test } from 'node:test'

import { Window } from 'happy-dom'

const domWindow = new Window()
for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'Node',
  'Element',
] as const) {
  Object.defineProperty(globalThis, key, {
    configurable: true,
    value: domWindow[key],
  })
}

const { act } = await import('react')
const { createRoot } = await import('react-dom/client')
const i18next = (await import('i18next')).default
const { initReactI18next } = await import('react-i18next')

await i18next.use(initReactI18next).init({ lng: 'en', resources: {} })

const { LmmBrandMark } = await import('@/components/lmm-brand-mark')
const { HowItWorks } = await import('./how-it-works')

const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

describe('home onboarding and brand', () => {
  after(() => domWindow.close())

  test('keeps all three onboarding steps readable without observer-gated opacity', async () => {
    const container = document.createElement('div')
    const root = createRoot(container)
    await act(async () => root.render(<HowItWorks />))

    const section = container.querySelector('[data-home-onboarding]')
    const steps = [...container.querySelectorAll('ol > li')]
    assert.ok(section)
    assert.equal(steps.length, 3)
    assert.deepEqual(
      steps.map((step) => step.querySelector('h3')?.textContent),
      ['Connect', 'Configure routes', 'Monitor']
    )
    assert.equal(section.querySelectorAll('.opacity-0').length, 0)
    assert.equal(section.className.includes('min-h-'), false)

    await act(async () => root.unmount())
  })

  test('exposes an original lmm.best mark with the constrained ink palette', async () => {
    const container = document.createElement('div')
    const root = createRoot(container)
    await act(async () =>
      root.render(<LmmBrandMark title='lmm.best home' data-brand-mark />)
    )

    const mark = container.querySelector('svg[data-brand-mark]')
    assert.ok(mark)
    assert.equal(mark.getAttribute('role'), 'img')
    assert.equal(mark.getAttribute('aria-label'), 'lmm.best home')
    assert.equal(mark.innerHTML.includes('#BCD1CA'), true)
    assert.equal(mark.innerHTML.includes('#141413'), true)
    assert.equal(mark.innerHTML.includes('#FAF9F5'), true)

    await act(async () => root.unmount())
  })
})
