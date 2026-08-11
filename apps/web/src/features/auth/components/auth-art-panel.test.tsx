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
const { createInstance } = await import('i18next')
const { I18nextProvider, initReactI18next } = await import('react-i18next')
const { AuthArtPanel } = await import('./auth-art-panel')

const i18n = createInstance()
await i18n.use(initReactI18next).init({
  lng: 'en',
  resources: { en: { translation: {} } },
})

const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

async function renderArtwork() {
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () =>
    root.render(
      <I18nextProvider i18n={i18n}>
        <AuthArtPanel />
      </I18nextProvider>
    )
  )
  return { container, root }
}

afterEach(() => document.body.replaceChildren())
after(() => domWindow.close())

describe('AuthArtPanel', () => {
  test('renders a current Responses API example with a live visual signal', async () => {
    const rendered = await renderArtwork()
    const preview = rendered.container.querySelector(
      '[data-live-request-preview]'
    )

    assert.ok(preview)
    assert.equal(
      preview.querySelector('[data-request-endpoint]')?.textContent?.trim(),
      '/v1/responses'
    )
    assert.equal(
      preview.querySelector('[data-request-model]')?.textContent?.trim(),
      'gpt-5.6-terra'
    )
    assert.ok(preview.querySelector('.auth-art-request-sweep'))
    assert.ok(preview.querySelector('.auth-art-request-pulse'))

    await act(async () => rendered.root.unmount())
  })

  test('does not regress to the retired gpt-4o static example', () => {
    const source = readFileSync(
      new URL('./auth-art-panel.tsx', import.meta.url),
      'utf8'
    )
    const styles = readFileSync(
      new URL('../../../styles/index.css', import.meta.url),
      'utf8'
    )

    assert.equal(source.includes('gpt-4o'), false)
    assert.match(source, /REQUEST_MODELS/)
    assert.match(source, /setInterval/)
    assert.match(styles, /@keyframes auth-art-request-sweep/)
    assert.match(styles, /\.auth-art-request-pulse/)
  })
})
