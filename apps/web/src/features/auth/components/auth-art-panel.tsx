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
import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'

const ART_WIDTH = 720
const ART_HEIGHT = 900
const INFLUENCE_RADIUS = 145
const MAX_DISPLACEMENT = 9
const FOUNDATION_MAX_DISPLACEMENT = 2
const SPRING_FREQUENCY = 14.5
const SURFACE_SPRING_FREQUENCY = 16.5
const MAX_SURFACE_TRANSLATION = 12
const MAX_SURFACE_TILT = 4
const MAX_POINTER_VELOCITY = 1200

type MotionValue = {
  current: number
  target: number
  velocity: number
}

type FieldElement = {
  element: SVGGraphicsElement
  samples: Array<{ x: number; y: number }>
  baseTransform: string
  mass: number
  maxDisplacement: number
  x: MotionValue
  y: MotionValue
}

const CONTRIBUTION_PATHS = [
  {
    d: 'M 34 343 C 82 316 119 326 164 352 S 240 394 300 382 S 377 404 430 454',
    opacity: 0.72,
    width: 1.8,
    mass: 0.82,
  },
  {
    d: 'M 38 374 C 92 354 128 371 175 399 S 256 417 313 410 S 385 432 430 454',
    opacity: 0.5,
    width: 1.35,
    mass: 1.06,
  },
  {
    d: 'M 45 405 C 97 392 139 411 187 433 S 278 438 332 441 S 397 450 430 454',
    opacity: 0.64,
    width: 1.6,
    mass: 0.94,
  },
  {
    d: 'M 37 438 C 92 434 128 453 181 466 S 266 462 327 459 S 393 456 430 454',
    opacity: 0.42,
    width: 1.2,
    mass: 1.18,
  },
  {
    d: 'M 46 470 C 98 481 139 482 194 485 S 276 477 341 468 S 402 458 430 454',
    opacity: 0.7,
    width: 1.75,
    mass: 0.88,
  },
  {
    d: 'M 64 501 C 119 518 156 509 205 494 S 295 479 354 467 S 405 457 430 454',
    opacity: 0.48,
    width: 1.3,
    mass: 1.22,
  },
  {
    d: 'M 91 531 C 140 546 183 530 226 507 S 310 481 365 469 S 411 458 430 454',
    opacity: 0.62,
    width: 1.55,
    mass: 0.97,
  },
  {
    d: 'M 126 562 C 170 562 208 541 246 518 S 323 484 374 470 S 416 458 430 454',
    opacity: 0.38,
    width: 1.15,
    mass: 1.3,
  },
  {
    d: 'M 171 590 C 207 577 232 551 266 525 S 332 486 382 470 S 420 457 430 454',
    opacity: 0.58,
    width: 1.45,
    mass: 1.1,
  },
  {
    d: 'M 86 307 C 119 323 151 326 185 345 S 244 367 297 375 S 383 410 430 454',
    opacity: 0.44,
    width: 1.2,
    mass: 1.16,
  },
  {
    d: 'M 154 285 C 175 317 213 331 241 349 S 299 366 336 387 S 399 432 430 454',
    opacity: 0.69,
    width: 1.7,
    mass: 0.9,
  },
  {
    d: 'M 229 278 C 237 314 271 335 291 355 S 339 382 366 407 S 406 442 430 454',
    opacity: 0.4,
    width: 1.2,
    mass: 1.26,
  },
  {
    d: 'M 305 286 C 304 322 324 345 341 367 S 374 415 430 454',
    opacity: 0.63,
    width: 1.55,
    mass: 0.98,
  },
  {
    d: 'M 375 292 C 365 328 370 354 383 380 S 404 428 430 454',
    opacity: 0.47,
    width: 1.3,
    mass: 1.12,
  },
  {
    d: 'M 676 328 C 626 321 600 344 566 368 S 512 415 470 438 S 444 450 430 454',
    opacity: 0.68,
    width: 1.7,
    mass: 0.86,
  },
  {
    d: 'M 682 367 C 632 352 595 373 561 397 S 506 430 468 444 S 442 452 430 454',
    opacity: 0.43,
    width: 1.2,
    mass: 1.24,
  },
  {
    d: 'M 680 409 C 625 391 591 410 554 429 S 494 448 456 452 S 439 454 430 454',
    opacity: 0.6,
    width: 1.5,
    mass: 1.02,
  },
  {
    d: 'M 678 451 C 621 443 587 451 548 456 S 486 456 453 455 S 438 454 430 454',
    opacity: 0.36,
    width: 1.1,
    mass: 1.34,
  },
  {
    d: 'M 430 454 C 452 466 459 490 480 512 S 493 526 500 530',
    opacity: 0.76,
    width: 1.9,
    mass: 0.8,
  },
  {
    d: 'M 430 454 C 449 483 454 511 477 532 S 493 548 500 552',
    opacity: 0.54,
    width: 1.4,
    mass: 1.08,
  },
  {
    d: 'M 430 454 C 438 500 451 533 475 555 S 491 570 500 574',
    opacity: 0.66,
    width: 1.65,
    mass: 0.92,
  },
  {
    d: 'M 430 454 C 474 450 510 465 528 496 C 548 529 537 554 534 574',
    opacity: 0.4,
    width: 1.2,
    mass: 1.2,
  },
] as const

const CONTRIBUTION_NODES = [
  { x: 86, y: 307, r: 4, tone: 'ink', mass: 1.08 },
  { x: 119, y: 326, r: 3, tone: 'paper', mass: 0.86 },
  { x: 154, y: 285, r: 4.5, tone: 'clay', mass: 1.16 },
  { x: 175, y: 399, r: 3.5, tone: 'paper', mass: 0.92 },
  { x: 187, y: 433, r: 4, tone: 'ink', mass: 1.22 },
  { x: 205, y: 494, r: 3.5, tone: 'paper', mass: 0.84 },
  { x: 226, y: 507, r: 4.5, tone: 'sage', mass: 1.12 },
  { x: 266, y: 525, r: 3, tone: 'ink', mass: 0.96 },
  { x: 297, y: 375, r: 3.5, tone: 'paper', mass: 1.26 },
  { x: 336, y: 387, r: 4, tone: 'ink', mass: 0.9 },
  { x: 365, y: 469, r: 3.5, tone: 'paper', mass: 1.18 },
  { x: 383, y: 380, r: 3, tone: 'sage', mass: 1.02 },
  { x: 430, y: 454, r: 6, tone: 'clay', mass: 0.8 },
  { x: 470, y: 438, r: 3.5, tone: 'paper', mass: 1.14 },
  { x: 506, y: 430, r: 3, tone: 'ink', mass: 0.94 },
  { x: 554, y: 429, r: 4, tone: 'paper', mass: 1.28 },
  { x: 595, y: 373, r: 3.5, tone: 'sage', mass: 0.88 },
  { x: 625, y: 391, r: 3, tone: 'ink', mass: 1.2 },
  { x: 480, y: 512, r: 3.5, tone: 'paper', mass: 1.04 },
  { x: 477, y: 555, r: 4, tone: 'ink', mass: 0.9 },
] as const

const FIELD_LABELS = [
  { label: 'ISSUE', x: 57, y: 330, line: 'M 57 337 H 96', mass: 0.9 },
  { label: 'BOUNTY', x: 70, y: 458, line: 'M 70 465 H 119', mass: 1.18 },
  { label: 'PATCH', x: 232, y: 306, line: 'M 232 313 H 272', mass: 1.04 },
  { label: 'PR', x: 335, y: 426, line: 'M 335 433 H 358', mass: 0.84 },
  { label: 'REVIEW', x: 583, y: 343, line: 'M 583 350 H 633', mass: 1.22 },
] as const

const FOUNDATION_TICKS = [
  { x: 66, h: 13, mass: 0.88 },
  { x: 84, h: 7, mass: 1.16 },
  { x: 104, h: 18, mass: 0.96 },
  { x: 126, h: 10, mass: 1.28 },
  { x: 151, h: 15, mass: 1.04 },
  { x: 177, h: 8, mass: 1.22 },
  { x: 206, h: 17, mass: 0.9 },
  { x: 238, h: 11, mass: 1.12 },
  { x: 273, h: 15, mass: 1.3 },
  { x: 311, h: 7, mass: 0.94 },
  { x: 351, h: 18, mass: 1.18 },
  { x: 394, h: 10, mass: 1.02 },
  { x: 439, h: 14, mass: 1.26 },
  { x: 487, h: 8, mass: 0.86 },
  { x: 538, h: 17, mass: 1.14 },
  { x: 592, h: 10, mass: 0.98 },
  { x: 649, h: 15, mass: 1.24 },
] as const

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(Math.max(value, minimum), maximum)
}

function elementSamples(element: SVGGraphicsElement) {
  const geometry = element as SVGGeometryElement

  if (typeof geometry.getTotalLength === 'function') {
    try {
      const length = geometry.getTotalLength()
      const sampleCount = clamp(Math.ceil(length / 42), 2, 18)

      return Array.from({ length: sampleCount + 1 }, (_, index) => {
        const point = geometry.getPointAtLength((length * index) / sampleCount)
        return { x: point.x, y: point.y }
      })
    } catch {
      // Fall through to the bounding-box anchor for grouped artwork.
    }
  }

  const bounds = element.getBBox()
  return [
    {
      x: bounds.x + bounds.width / 2,
      y: bounds.y + bounds.height / 2,
    },
  ]
}

function tokenFill(tone: (typeof CONTRIBUTION_NODES)[number]['tone']) {
  if (tone === 'clay') return 'var(--art-clay)'
  if (tone === 'sage') return 'var(--art-sage)'
  if (tone === 'paper') return 'var(--art-field)'
  return 'var(--art-ink)'
}

export function AuthArtPanel() {
  const { t } = useTranslation()
  const panelRef = useRef<HTMLElement>(null)
  const surfaceRef = useRef<HTMLDivElement>(null)
  const svgRef = useRef<SVGSVGElement>(null)

  useEffect(() => {
    const panel = panelRef.current
    const surface = surfaceRef.current
    const svg = svgRef.current
    if (!panel || !surface || !svg) return

    const fieldElements: FieldElement[] = Array.from(
      svg.querySelectorAll<SVGGraphicsElement>('[data-field]')
    ).map((element) => ({
      element,
      samples: elementSamples(element),
      baseTransform: element.getAttribute('transform') ?? '',
      mass: clamp(Number(element.dataset.mass) || 1, 0.72, 1.36),
      maxDisplacement:
        element.dataset.field === 'foundation'
          ? FOUNDATION_MAX_DISPLACEMENT
          : MAX_DISPLACEMENT,
      x: { current: 0, target: 0, velocity: 0 },
      y: { current: 0, target: 0, velocity: 0 },
    }))
    const desktopQuery = window.matchMedia('(min-width: 1024px)')
    const finePointerQuery = window.matchMedia('(pointer: fine)')
    const reducedMotionQuery = window.matchMedia(
      '(prefers-reduced-motion: reduce)'
    )
    const surfaceMotion = {
      x: { current: 0, target: 0, velocity: 0 },
      y: { current: 0, target: 0, velocity: 0 },
      rotateX: { current: 0, target: 0, velocity: 0 },
      rotateY: { current: 0, target: 0, velocity: 0 },
    } satisfies Record<string, MotionValue>
    const surfaceValues = [
      surfaceMotion.x,
      surfaceMotion.y,
      surfaceMotion.rotateX,
      surfaceMotion.rotateY,
    ]
    let animationFrame: number | null = null
    let previousTime = 0
    let previousPointerX: number | null = null
    let previousPointerY: number | null = null
    let previousPointerTime = 0
    let pointerVelocityX = 0
    let pointerVelocityY = 0
    let listening = false

    const render = () => {
      const shadowX = clamp(
        -surfaceMotion.x.current * 0.5 - surfaceMotion.rotateY.current * 1.1,
        -10,
        10
      )
      const shadowY =
        18 +
        clamp(
          surfaceMotion.y.current * 0.35 + surfaceMotion.rotateX.current * 0.8,
          -4,
          4
        )
      const shadowBlur =
        42 +
        (Math.abs(surfaceMotion.rotateX.current) +
          Math.abs(surfaceMotion.rotateY.current)) *
          1.6

      surface.style.transform = `perspective(1200px) translate3d(${surfaceMotion.x.current.toFixed(2)}px, ${surfaceMotion.y.current.toFixed(2)}px, 0) rotateX(${surfaceMotion.rotateX.current.toFixed(2)}deg) rotateY(${surfaceMotion.rotateY.current.toFixed(2)}deg)`
      surface.style.boxShadow = `${shadowX.toFixed(2)}px ${shadowY.toFixed(2)}px ${shadowBlur.toFixed(2)}px var(--art-shadow)`
      fieldElements.forEach((field) => {
        const translation = `translate(${field.x.current.toFixed(2)} ${field.y.current.toFixed(2)})`
        field.element.setAttribute(
          'transform',
          field.baseTransform
            ? `${field.baseTransform} ${translation}`
            : translation
        )
      })
    }

    const settle = (time: number) => {
      const delta = previousTime
        ? Math.min((time - previousTime) / 1000, 0.032)
        : 1 / 60
      previousTime = time
      const surfaceStiffness =
        SURFACE_SPRING_FREQUENCY * SURFACE_SPRING_FREQUENCY
      const surfaceDamping = 2 * SURFACE_SPRING_FREQUENCY
      let moving = false

      fieldElements.forEach((field) => {
        const frequency = SPRING_FREQUENCY / Math.sqrt(field.mass)
        const stiffness = frequency * frequency
        const damping = 2 * frequency

        ;[field.x, field.y].forEach((value) => {
          const acceleration =
            stiffness * (value.target - value.current) -
            damping * value.velocity
          value.velocity += acceleration * delta
          value.current += value.velocity * delta

          if (
            Math.abs(value.target - value.current) > 0.025 ||
            Math.abs(value.velocity) > 0.04
          ) {
            moving = true
          } else {
            value.current = value.target
            value.velocity = 0
          }
        })
      })

      surfaceValues.forEach((value) => {
        const acceleration =
          surfaceStiffness * (value.target - value.current) -
          surfaceDamping * value.velocity
        value.velocity += acceleration * delta
        value.current += value.velocity * delta

        if (
          Math.abs(value.target - value.current) > 0.02 ||
          Math.abs(value.velocity) > 0.08
        ) {
          moving = true
        } else {
          value.current = value.target
          value.velocity = 0
        }
      })

      render()
      if (moving) {
        animationFrame = window.requestAnimationFrame(settle)
      } else {
        animationFrame = null
        previousTime = 0
        surface.style.willChange = 'auto'
      }
    }

    const requestSettle = () => {
      if (animationFrame === null) {
        previousTime = 0
        surface.style.willChange = 'transform, box-shadow'
        animationFrame = window.requestAnimationFrame(settle)
      }
    }

    const releaseMotion = () => {
      fieldElements.forEach((field) => {
        field.x.target = 0
        field.y.target = 0
      })
      surfaceValues.forEach((value) => {
        value.target = 0
      })
      previousPointerX = null
      previousPointerY = null
      previousPointerTime = 0
      pointerVelocityX = 0
      pointerVelocityY = 0
      requestSettle()
    }

    const moveMotion = (event: PointerEvent) => {
      const bounds = panel.getBoundingClientRect()
      const normalizedX = clamp(
        (event.clientX - bounds.left - bounds.width / 2) / (bounds.width / 2),
        -1,
        1
      )
      const normalizedY = clamp(
        (event.clientY - bounds.top - bounds.height / 2) / (bounds.height / 2),
        -1,
        1
      )

      if (previousPointerX !== null && previousPointerY !== null) {
        const elapsed =
          Math.max(event.timeStamp - previousPointerTime, 8) / 1000
        const measuredVelocityX = clamp(
          (event.clientX - previousPointerX) / elapsed,
          -MAX_POINTER_VELOCITY,
          MAX_POINTER_VELOCITY
        )
        const measuredVelocityY = clamp(
          (event.clientY - previousPointerY) / elapsed,
          -MAX_POINTER_VELOCITY,
          MAX_POINTER_VELOCITY
        )
        pointerVelocityX = pointerVelocityX * 0.55 + measuredVelocityX * 0.45
        pointerVelocityY = pointerVelocityY * 0.55 + measuredVelocityY * 0.45
      }
      previousPointerX = event.clientX
      previousPointerY = event.clientY
      previousPointerTime = event.timeStamp

      surfaceMotion.x.target = clamp(
        normalizedX * 7.5 + pointerVelocityX * 0.0035,
        -MAX_SURFACE_TRANSLATION,
        MAX_SURFACE_TRANSLATION
      )
      surfaceMotion.y.target = clamp(
        normalizedY * 7.5 + pointerVelocityY * 0.0035,
        -MAX_SURFACE_TRANSLATION,
        MAX_SURFACE_TRANSLATION
      )
      surfaceMotion.rotateX.target = clamp(
        -normalizedY * 3.2 - pointerVelocityY * 0.00065,
        -MAX_SURFACE_TILT,
        MAX_SURFACE_TILT
      )
      surfaceMotion.rotateY.target = clamp(
        normalizedX * 3.2 + pointerVelocityX * 0.00065,
        -MAX_SURFACE_TILT,
        MAX_SURFACE_TILT
      )

      const matrix = svg.getScreenCTM()
      if (!matrix) return

      const cursor = svg.createSVGPoint()
      cursor.x = event.clientX
      cursor.y = event.clientY
      const localCursor = cursor.matrixTransform(matrix.inverse())

      fieldElements.forEach((field) => {
        let nearest = field.samples[0]
        let nearestDistance = Number.POSITIVE_INFINITY

        field.samples.forEach((sample) => {
          const distance = Math.hypot(
            sample.x - localCursor.x,
            sample.y - localCursor.y
          )
          if (distance < nearestDistance) {
            nearest = sample
            nearestDistance = distance
          }
        })

        if (nearestDistance >= INFLUENCE_RADIUS) {
          field.x.target = 0
          field.y.target = 0
          return
        }

        const deltaX = nearest.x - localCursor.x
        const deltaY = nearest.y - localCursor.y
        const falloff = (1 - nearestDistance / INFLUENCE_RADIUS) ** 2
        const massScale = clamp(1.12 - field.mass * 0.14, 0.78, 1)
        const limit = field.maxDisplacement * falloff * massScale
        const distanceScale = limit / Math.max(nearestDistance, 1)
        const baseX = deltaX * distanceScale
        const baseY = nearestDistance < 1 ? -limit : deltaY * distanceScale
        const momentumX = (pointerVelocityX * 0.0012 * falloff) / field.mass
        const momentumY = (pointerVelocityY * 0.0012 * falloff) / field.mass
        const rawX = baseX + momentumX
        const rawY = baseY + momentumY
        const magnitude = Math.hypot(rawX, rawY)
        const limitScale = magnitude > limit ? limit / magnitude : 1

        field.x.target = rawX * limitScale
        field.y.target = rawY * limitScale
      })

      requestSettle()
    }

    const resetMotion = () => {
      if (animationFrame !== null) {
        window.cancelAnimationFrame(animationFrame)
        animationFrame = null
      }
      previousTime = 0
      fieldElements.forEach((field) => {
        field.x.current = 0
        field.x.target = 0
        field.x.velocity = 0
        field.y.current = 0
        field.y.target = 0
        field.y.velocity = 0
      })
      surfaceValues.forEach((value) => {
        value.current = 0
        value.target = 0
        value.velocity = 0
      })
      previousPointerX = null
      previousPointerY = null
      previousPointerTime = 0
      pointerVelocityX = 0
      pointerVelocityY = 0
      surface.style.willChange = 'auto'
      render()
    }

    const handleVisibilityChange = () => {
      if (document.hidden) resetMotion()
    }

    const syncPointerBehavior = () => {
      const shouldListen =
        desktopQuery.matches &&
        finePointerQuery.matches &&
        !reducedMotionQuery.matches

      if (shouldListen === listening) return
      listening = shouldListen

      if (listening) {
        panel.addEventListener('pointermove', moveMotion)
        panel.addEventListener('pointerleave', releaseMotion)
      } else {
        panel.removeEventListener('pointermove', moveMotion)
        panel.removeEventListener('pointerleave', releaseMotion)
        resetMotion()
      }
    }

    desktopQuery.addEventListener('change', syncPointerBehavior)
    finePointerQuery.addEventListener('change', syncPointerBehavior)
    reducedMotionQuery.addEventListener('change', syncPointerBehavior)
    document.addEventListener('visibilitychange', handleVisibilityChange)
    syncPointerBehavior()
    render()

    return () => {
      panel.removeEventListener('pointermove', moveMotion)
      panel.removeEventListener('pointerleave', releaseMotion)
      desktopQuery.removeEventListener('change', syncPointerBehavior)
      finePointerQuery.removeEventListener('change', syncPointerBehavior)
      reducedMotionQuery.removeEventListener('change', syncPointerBehavior)
      document.removeEventListener('visibilitychange', handleVisibilityChange)
      if (animationFrame !== null) {
        window.cancelAnimationFrame(animationFrame)
      }
    }
  }, [])

  return (
    <aside
      ref={panelRef}
      aria-hidden='true'
      className='relative h-full min-h-0 overflow-visible p-4 [perspective:1200px]'
    >
      <div
        ref={surfaceRef}
        className='pointer-events-none absolute inset-4 [transform-origin:50%_50%] overflow-hidden rounded-[2rem] border [border-color:var(--art-border)] bg-[var(--art-surface)] text-[var(--art-ink)] select-none [--art-border:rgba(20,20,19,0.2)] [--art-clay:#D97757] [--art-field:#FAF9F5] [--art-foundation:#141413] [--art-ink:#141413] [--art-muted:#5E5A52] [--art-on-foundation:#FAF9F5] [--art-sage:#788C5D] [--art-shadow:rgba(35,30,22,0.2)] [--art-surface:#E3DACC] [transform-style:preserve-3d] dark:[--art-border:rgba(250,249,245,0.18)] dark:[--art-clay:#E58A68] dark:[--art-field:#24231F] dark:[--art-foundation:#EEE8DC] dark:[--art-ink:#FAF9F5] dark:[--art-muted:#CDC6B9] dark:[--art-on-foundation:#181815] dark:[--art-sage:#AABD98] dark:[--art-shadow:rgba(0,0,0,0.5)] dark:[--art-surface:#181815]'
      >
        <svg
          ref={svgRef}
          viewBox={`0 0 ${ART_WIDTH} ${ART_HEIGHT}`}
          preserveAspectRatio='xMidYMid meet'
          focusable='false'
          className='h-full w-full'
          xmlns='http://www.w3.org/2000/svg'
        >
          <path
            d='M 30 265 C 102 231 207 243 276 256 C 358 271 439 245 523 259 C 610 273 683 318 686 410 C 689 500 652 602 562 643 C 470 684 360 633 278 650 C 187 668 91 641 48 571 C 11 510 0 347 30 265 Z'
            fill='var(--art-field)'
          />

          <path
            data-field='upper'
            data-mass='0.9'
            d='M 52 57 H 168'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='2'
          />
          <path
            data-field='upper'
            data-mass='1.2'
            d='M 557 57 H 668'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='2'
          />
          <path
            data-field='upper'
            data-mass='1.08'
            d='M 52 244 C 211 242 340 248 479 244 S 607 241 668 244'
            fill='none'
            stroke='currentColor'
            strokeOpacity='.18'
            strokeWidth='1'
          />

          <g fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'>
            <text
              x='52'
              y='87'
              fill='var(--art-muted)'
              fontSize='11'
              fontWeight='700'
              letterSpacing='2.25'
            >
              {t('LMM / OPEN-SOURCE BOUNTY FIELD')}
            </text>
            <circle
              data-field='upper'
              data-mass='0.84'
              cx='654'
              cy='84'
              r='5'
              fill='var(--art-clay)'
            />
            <text
              x='642'
              y='109'
              fill='var(--art-muted)'
              fontSize='9'
              letterSpacing='1.45'
              textAnchor='end'
            >
              {t('LIVE CONTRIBUTIONS')}
            </text>
          </g>

          <text
            x='52'
            y='170'
            fill='currentColor'
            fontFamily='Georgia, Times New Roman, serif'
            fontSize='43'
            letterSpacing='-1.45'
          >
            {t('Build in public. Earn access.')}
          </text>
          <text
            x='54'
            y='204'
            fill='var(--art-muted)'
            fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
            fontSize='10.5'
            letterSpacing='.42'
          >
            {t('Verified open-source work becomes usable model access.')}
          </text>

          <g
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeLinejoin='round'
          >
            {CONTRIBUTION_PATHS.map((path) => (
              <path
                key={path.d}
                data-field='upper'
                data-mass={path.mass}
                d={path.d}
                strokeOpacity={path.opacity}
                strokeWidth={path.width}
              />
            ))}
          </g>

          {CONTRIBUTION_NODES.map((node) => (
            <circle
              key={`${node.x}-${node.y}`}
              data-field='upper'
              data-mass={node.mass}
              cx={node.x}
              cy={node.y}
              r={node.r}
              fill={tokenFill(node.tone)}
              stroke='var(--art-ink)'
              strokeWidth='1.4'
            />
          ))}

          <g
            fill='var(--art-ink)'
            fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
            fontSize='9'
            fontWeight='700'
            letterSpacing='1.45'
          >
            {FIELD_LABELS.map((label) => (
              <g key={label.label} data-field='upper' data-mass={label.mass}>
                <text x={label.x} y={label.y}>
                  {label.label}
                </text>
                <path
                  d={label.line}
                  fill='none'
                  stroke='currentColor'
                  strokeLinecap='round'
                  strokeOpacity='.48'
                />
              </g>
            ))}
          </g>

          <g
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeLinejoin='round'
          >
            <path
              data-field='upper'
              data-mass='.82'
              d='M 500 530 C 516 529 518 547 535 552'
              strokeWidth='2.6'
            />
            <path
              data-field='upper'
              data-mass='1.14'
              d='M 500 552 C 516 553 522 552 535 552'
              strokeWidth='2.3'
            />
            <path
              data-field='upper'
              data-mass='.94'
              d='M 500 574 C 516 573 519 557 535 552'
              strokeWidth='2.7'
            />
            <path
              data-field='upper'
              data-mass='1.08'
              d='M 535 552 C 571 552 567 601 593 623 C 609 637 614 659 614 690'
              strokeWidth='3'
            />
            {[530, 552, 574].map((y, index) => (
              <circle
                key={y}
                data-field='upper'
                data-mass={[1.18, 0.86, 1.06][index]}
                cx='500'
                cy={y}
                r='3.6'
                fill='var(--art-field)'
                strokeWidth='1.5'
              />
            ))}
            <circle
              data-field='upper'
              data-mass='.88'
              cx='535'
              cy='552'
              r='5.5'
              fill='var(--art-sage)'
              strokeWidth='1.7'
            />
            <circle
              data-field='upper'
              data-mass='1.16'
              cx='614'
              cy='655'
              r='4'
              fill='var(--art-clay)'
              strokeWidth='1.4'
            />
          </g>

          <g
            data-field='upper'
            data-mass='.92'
            fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
          >
            <text
              x='548'
              y='576'
              fill='var(--art-ink)'
              fontSize='9'
              fontWeight='700'
              letterSpacing='1.4'
            >
              {t('MERGED')}
            </text>
            <path
              d='M 548 584 C 571 582 588 585 605 583'
              fill='none'
              stroke='currentColor'
              strokeLinecap='round'
              strokeOpacity='.5'
            />
          </g>

          <path
            data-field='foundation'
            data-mass='1.28'
            d='M 38 690 C 159 686 266 694 361 690 C 462 686 558 693 682 689 L 682 835 C 563 840 452 833 356 837 C 245 841 148 833 38 838 Z'
            fill='var(--art-foundation)'
            stroke='var(--art-ink)'
            strokeLinejoin='round'
            strokeWidth='1.4'
          />

          <text
            x='64'
            y='733'
            fill='var(--art-on-foundation)'
            fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
            fontSize='12'
            fontWeight='700'
            letterSpacing='2'
          >
            {t('API.LMM.BEST / TOKEN SERVICE')}
          </text>
          <text
            x='64'
            y='758'
            fill='var(--art-on-foundation)'
            fillOpacity='.68'
            fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
            fontSize='9.5'
            letterSpacing='.65'
          >
            {t('stable access layer')}
          </text>

          <g
            fill='none'
            stroke='var(--art-on-foundation)'
            strokeLinecap='round'
          >
            <path
              data-field='foundation'
              data-mass='.9'
              d='M 64 779 H 246'
              strokeOpacity='.34'
            />
            <path
              data-field='foundation'
              data-mass='1.18'
              d='M 269 779 H 451'
              strokeOpacity='.34'
            />
            <path
              data-field='foundation'
              data-mass='1.3'
              d='M 474 779 H 654'
              strokeOpacity='.34'
            />
          </g>

          {[
            { x: 64, label: 'TOKEN', value: 'earned', mass: 0.86 },
            { x: 269, label: 'ACCOUNT', value: 'ready', mass: 1.12 },
            { x: 474, label: '/V1 API', value: 'available', mass: 1.28 },
          ].map((indicator, index) => (
            <g
              key={indicator.label}
              data-field='foundation'
              data-mass={indicator.mass}
              fill='var(--art-on-foundation)'
              fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
            >
              <circle
                cx={indicator.x + 6}
                cy='803'
                r='4'
                fill={index === 0 ? 'var(--art-clay)' : 'var(--art-sage)'}
                stroke='var(--art-on-foundation)'
                strokeWidth='1'
              />
              <path
                d={`M ${indicator.x + 18} 803 H ${indicator.x + 36}`}
                fill='none'
                stroke='var(--art-on-foundation)'
                strokeOpacity='.5'
                strokeLinecap='round'
              />
              <text
                x={indicator.x + 44}
                y='806'
                fontSize='9'
                fontWeight='700'
                letterSpacing='1.1'
              >
                {indicator.label}
              </text>
              <text
                x={indicator.x + 121}
                y='806'
                fill='var(--art-on-foundation)'
                fillOpacity='.58'
                fontSize='8.5'
                textAnchor='end'
              >
                {indicator.value}
              </text>
            </g>
          ))}

          <g
            fill='none'
            stroke='var(--art-on-foundation)'
            strokeLinecap='round'
            strokeOpacity='.27'
          >
            {FOUNDATION_TICKS.map((tick) => (
              <path
                key={tick.x}
                data-field='foundation'
                data-mass={tick.mass}
                d={`M ${tick.x} 827 V ${827 - tick.h}`}
              />
            ))}
          </g>
        </svg>
      </div>
    </aside>
  )
}
