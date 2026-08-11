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

import {
  consumeQueuedAssistantPreset,
  requestAssistantOpen,
  subscribeToAssistantOpen,
} from './assistant-events'

const domWindow = new Window({ url: 'https://console.example.test/' })
Object.defineProperty(globalThis, 'window', {
  configurable: true,
  value: domWindow,
})
Object.defineProperty(globalThis, 'CustomEvent', {
  configurable: true,
  value: domWindow.CustomEvent,
})

afterEach(() => {
  consumeQueuedAssistantPreset()
  window.sessionStorage.clear()
})

after(() => domWindow.close())

describe('assistant open events', () => {
  test('queues a preset for redirects that remount the layout', () => {
    requestAssistantOpen('api-key')
    assert.equal(consumeQueuedAssistantPreset(), 'api-key')
    assert.equal(consumeQueuedAssistantPreset(), undefined)
  })

  test('notifies an already-mounted launcher', () => {
    let received: string | undefined
    const unsubscribe = subscribeToAssistantOpen((preset) => {
      received = preset
    })

    requestAssistantOpen('plan')
    unsubscribe()

    assert.equal(received, 'plan')
    assert.equal(consumeQueuedAssistantPreset(), undefined)
  })
})
