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
import { readFileSync } from 'node:fs'
import { after, afterEach, describe, test } from 'node:test'

import { Window } from 'happy-dom'

const domWindow = new Window()
for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'SVGElement',
  'Node',
  'Element',
  'Event',
  'MouseEvent',
] as const) {
  Object.defineProperty(globalThis, key, {
    configurable: true,
    value: domWindow[key],
  })
}

const { act } = await import('react')
const { createRoot } = await import('react-dom/client')
const { AuthArtPanel } = await import('./auth-art-panel')

const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

async function renderArtwork() {
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => root.render(<AuthArtPanel />))
  return { container, root }
}

afterEach(() => document.body.replaceChildren())
after(() => domWindow.close())

describe('AuthArtPanel', () => {
  test('uses one ivory core and broad black handoff gestures', async () => {
    const rendered = await renderArtwork()
    assert.equal(
      rendered.container.querySelectorAll('.auth-art-carrier').length,
      0
    )
    assert.equal(
      rendered.container.querySelectorAll('.auth-art-core').length,
      1
    )
    assert.equal(
      rendered.container.querySelectorAll('.auth-art-left-gesture').length,
      1
    )
    assert.equal(
      rendered.container.querySelectorAll('.auth-art-right-gesture').length,
      1
    )
    assert.equal(rendered.container.querySelectorAll('[data-field]').length, 0)
    assert.equal(
      rendered.container.querySelectorAll('svg[aria-hidden="true"]').length,
      1
    )
    assert.equal(
      rendered.container.querySelectorAll('.auth-art-clay').length,
      1
    )

    await act(async () => rendered.root.unmount())
  })

  test('keeps the three insight choices keyboard-accessible', async () => {
    const rendered = await renderArtwork()
    const tabs = [
      ...rendered.container.querySelectorAll<HTMLButtonElement>('[role="tab"]'),
    ]
    assert.equal(tabs.length, 3)
    assert.equal(tabs[0].getAttribute('aria-selected'), 'true')
    assert.equal(tabs[1].getAttribute('aria-selected'), 'false')

    await act(async () => tabs[1].click())
    assert.equal(tabs[0].getAttribute('aria-selected'), 'false')
    assert.equal(tabs[1].getAttribute('aria-selected'), 'true')
    assert.equal(
      rendered.container
        .querySelector('[role="tabpanel"]')
        ?.getAttribute('aria-labelledby'),
      'auth-art-tab-1'
    )

    await act(async () => rendered.root.unmount())
  })

  test('contains no technical-web motion machinery or hairline art rules', () => {
    const source = readFileSync(
      new URL('./auth-art-panel.tsx', import.meta.url),
      'utf8'
    )
    const styles = readFileSync(
      new URL('../../../styles/index.css', import.meta.url),
      'utf8'
    )

    for (const forbidden of [
      'CONTRIBUTION_PATHS',
      'CONTRIBUTION_NODES',
      'requestAnimationFrame',
      'pointermove',
      'data-field',
      'auth-art-foundation',
    ]) {
      assert.equal(source.includes(forbidden), false, forbidden)
    }
    assert.equal(source.includes('auth-art-carrier'), false)
    assert.equal(
      styles.includes('.auth-art-surface svg path[data-field]'),
      false
    )
    assert.equal(styles.includes('stroke-width: 12'), true)
    assert.equal(styles.includes('stroke-width: 8'), false)
    assert.equal(
      styles.includes('--art-surface: var(--forge-cactus-dark);'),
      true
    )
    assert.equal(styles.includes('--art-field: var(--forge-paper-dark);'), true)
    assert.equal(
      styles.includes('--art-foundation: var(--forge-ink-light);'),
      true
    )
  })
})
