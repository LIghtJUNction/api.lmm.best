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
let reducedMotion = false
let nextFrameId = 1
let frameCallbacks = new Map<number, FrameRequestCallback>()
let cancelledFrames: number[] = []

Object.defineProperty(domWindow, 'matchMedia', {
  configurable: true,
  value: (query: string) => ({
    matches: query.includes('prefers-reduced-motion') && reducedMotion,
    media: query,
    onchange: null,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    addListener: () => undefined,
    removeListener: () => undefined,
    dispatchEvent: () => true,
  }),
})
Object.defineProperty(domWindow, 'requestAnimationFrame', {
  configurable: true,
  value: (callback: FrameRequestCallback) => {
    const id = nextFrameId
    nextFrameId += 1
    frameCallbacks.set(id, callback)
    return id
  },
})
Object.defineProperty(domWindow, 'cancelAnimationFrame', {
  configurable: true,
  value: (id: number) => {
    cancelledFrames.push(id)
    frameCallbacks.delete(id)
  },
})

for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'SVGElement',
  'SVGPathElement',
  'SVGCircleElement',
  'Node',
  'Element',
  'Event',
  'PointerEvent',
] as const) {
  Object.defineProperty(globalThis, key, {
    configurable: true,
    value: domWindow[key],
  })
}

const { act } = await import('react')
const { createRoot } = await import('react-dom/client')
const { ForgeBountyHeroArt } = await import('./forge-bounty-hero-art')

const reactTestGlobals = globalThis as typeof globalThis & {
  IS_REACT_ACT_ENVIRONMENT?: boolean
}
reactTestGlobals.IS_REACT_ACT_ENVIRONMENT = true

function runFrames(limit = 12) {
  for (let index = 0; index < limit && frameCallbacks.size > 0; index += 1) {
    const callbacks = [...frameCallbacks.values()]
    frameCallbacks.clear()
    for (const callback of callbacks) callback(index * 16.67)
  }
}

async function renderArtwork() {
  const container = document.createElement('div')
  document.body.append(container)
  const root = createRoot(container)
  await act(async () => root.render(<ForgeBountyHeroArt />))
  const wrapper = container.querySelector<HTMLElement>(
    '[data-forge-bounty-art="interactive"]'
  )
  assert.ok(wrapper)
  wrapper.getBoundingClientRect = () =>
    ({
      x: 0,
      y: 0,
      top: 0,
      left: 0,
      right: 720,
      bottom: 560,
      width: 720,
      height: 560,
      toJSON: () => undefined,
    }) as DOMRect
  return { container, root, wrapper }
}

async function movePointer(wrapper: HTMLElement, x: number, y: number) {
  await act(async () => {
    wrapper.dispatchEvent(
      new PointerEvent('pointermove', {
        bubbles: true,
        clientX: x,
        clientY: y,
        pointerType: 'mouse',
      })
    )
    runFrames(18)
  })
}

async function leavePointer(wrapper: HTMLElement) {
  await act(async () => {
    wrapper.dispatchEvent(
      new PointerEvent('pointerleave', {
        bubbles: true,
        pointerType: 'mouse',
      })
    )
    runFrames(180)
  })
}

afterEach(() => {
  reducedMotion = false
  frameCallbacks.clear()
  cancelledFrames = []
  document.body.replaceChildren()
})

after(() => domWindow.close())

describe('ForgeBountyHeroArt', () => {
  test('replaces the bitmap hero with a registered bounty field', async () => {
    const homeSource = readFileSync(
      new URL('./forge-home.tsx', import.meta.url),
      'utf8'
    )
    assert.equal(homeSource.includes('/forge-collaboration.webp'), false)
    assert.equal(homeSource.includes('before:bg-[#141413]'), false)
    assert.equal(homeSource.includes('before:bg-foreground'), true)

    const rendered = await renderArtwork()
    const contributionPaths = rendered.container.querySelectorAll(
      '[data-fluid-path="contribution"]'
    )
    const nodes = rendered.container.querySelectorAll('[data-fluid-node]')
    const registered = [
      ...rendered.container.querySelectorAll('[data-fluid-id]'),
    ]
    const ids = registered.map((element) =>
      element.getAttribute('data-fluid-id')
    )

    assert.equal(contributionPaths.length, 16)
    assert.equal(nodes.length, 22)
    assert.equal(new Set(ids).size, registered.length)
    assert.equal(rendered.container.querySelector('img'), null)

    await act(async () => rendered.root.unmount())
  })

  test('keeps every registered line and node in the same local pointer field', async () => {
    const rendered = await renderArtwork()
    const paths = [
      ...rendered.container.querySelectorAll<SVGPathElement>(
        '[data-fluid-path]'
      ),
    ]
    const nodes = [
      ...rendered.container.querySelectorAll<SVGCircleElement>(
        '[data-fluid-node]'
      ),
    ]
    const basePaths = new Map(
      paths.map((path) => [path, path.getAttribute('d')])
    )

    for (const path of paths) {
      const x = Number(path.getAttribute('data-anchor-x'))
      const y = Number(path.getAttribute('data-anchor-y'))
      await movePointer(rendered.wrapper, x, y)
      assert.notEqual(
        path.getAttribute('d'),
        basePaths.get(path),
        `${path.getAttribute('data-fluid-id')} did not deform`
      )
    }

    for (const node of nodes) {
      const x = Number(node.getAttribute('data-anchor-x'))
      const y = Number(node.getAttribute('data-anchor-y'))
      await movePointer(rendered.wrapper, x, y)
      assert.ok(
        node.getAttribute('transform'),
        `${node.getAttribute('data-fluid-id')} did not deform`
      )
    }

    await leavePointer(rendered.wrapper)
    for (const path of paths) {
      assert.equal(path.getAttribute('d'), basePaths.get(path))
    }
    for (const node of nodes) assert.equal(node.getAttribute('transform'), null)

    await act(async () => rendered.root.unmount())
  })

  test('leaves far artwork fixed and returns exactly to rest on pointer leave', async () => {
    const rendered = await renderArtwork()
    const farPath = rendered.container.querySelector<SVGPathElement>(
      '[data-fluid-id="paper-bounty"]'
    )
    const farNode = rendered.container.querySelector<SVGCircleElement>(
      '[data-fluid-id="node-01"]'
    )
    assert.ok(farPath)
    assert.ok(farNode)
    const basePath = farPath.getAttribute('d')

    await movePointer(rendered.wrapper, 700, 540)
    assert.equal(farPath.getAttribute('d'), basePath)
    assert.equal(farNode.getAttribute('transform'), null)

    const nearPath = rendered.container.querySelector<SVGPathElement>(
      '[data-fluid-id="paper-patch"]'
    )
    assert.ok(nearPath)
    const nearBase = nearPath.getAttribute('d')
    await movePointer(rendered.wrapper, 346, 245)
    assert.notEqual(nearPath.getAttribute('d'), nearBase)
    await act(async () => runFrames(240))
    assert.equal(
      frameCallbacks.size,
      0,
      'stationary pointer should allow the animation queue to drain'
    )
    await leavePointer(rendered.wrapper)
    assert.equal(nearPath.getAttribute('d'), nearBase)

    await act(async () => rendered.root.unmount())
  })

  test('does not schedule motion for reduced-motion users', async () => {
    reducedMotion = true
    const rendered = await renderArtwork()
    await movePointer(rendered.wrapper, 346, 245)
    assert.equal(frameCallbacks.size, 0)

    await act(async () => rendered.root.unmount())
  })

  test('cancels a pending animation frame when unmounted', async () => {
    const rendered = await renderArtwork()
    await act(async () => {
      rendered.wrapper.dispatchEvent(
        new PointerEvent('pointermove', {
          bubbles: true,
          clientX: 346,
          clientY: 245,
          pointerType: 'mouse',
        })
      )
    })
    assert.equal(frameCallbacks.size, 1)
    await act(async () => rendered.root.unmount())
    assert.equal(cancelledFrames.length, 1)
    assert.equal(frameCallbacks.size, 0)
  })
})
