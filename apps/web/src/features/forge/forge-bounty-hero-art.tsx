/*
Copyright (C) 2023-2026 QuantumNous

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

For commercial licensing, please contact support@quantumnous.com
*/
import {
  useCallback,
  useEffect,
  useRef,
  type PointerEvent as ReactPointerEvent,
} from 'react'
import { useTranslation } from 'react-i18next'

import styles from './forge-bounty-hero-art.module.css'

type Point = readonly [number, number]
type StageLabel = 'BOUNTY' | 'PATCH' | 'MERGED' | 'TOKEN'

type FluidPath = {
  id: string
  points: readonly Point[]
  className: string
  closed?: boolean
  kind: 'contribution' | 'connector' | 'surface' | 'detail'
}

type PaperLayer = {
  id: string
  depth: number
  center: Point
  paths: readonly FluidPath[]
  label: StageLabel
  labelPoint: Point
  labelClassName?: string
  secondaryLabel?: 'REVIEW'
  secondaryLabelPoint?: Point
}

type CardSpec = {
  id: string
  label: Exclude<StageLabel, 'TOKEN'>
  x: number
  y: number
  width: number
  height: number
  depth: number
  surfaceClassName: string
  labelClassName?: string
  secondaryLabel?: 'REVIEW'
}

type LedgerSpec = {
  id: string
  x: number
  y: number
  width: number
  height: number
  depth: number
}

const VIEWBOX_WIDTH = 720
const VIEWBOX_HEIGHT = 560
const POINTER_RADIUS = 132

// The drawing is authored from semantic stations. Every line, node, rule, and
// card is derived from these few values so the field can be resized without
// hand-editing a coordinate cloud.
const CARD_SPECS: readonly CardSpec[] = [
  {
    id: 'bounty-layer',
    label: 'BOUNTY',
    x: 52,
    y: 130,
    width: 168,
    height: 82,
    depth: 0.92,
    surfaceClassName: styles.surfaceClay,
  },
  {
    id: 'patch-layer',
    label: 'PATCH',
    x: 262,
    y: 232,
    width: 182,
    height: 94,
    depth: 0.62,
    surfaceClassName: styles.surfacePaper,
    labelClassName: styles.paperLabel,
    secondaryLabel: 'REVIEW',
  },
  {
    id: 'merged-layer',
    label: 'MERGED',
    x: 496,
    y: 130,
    width: 168,
    height: 82,
    depth: 0.76,
    surfaceClassName: styles.surfaceSage,
  },
]

const LEDGER_SPEC: LedgerSpec = {
  id: 'token-layer',
  x: 56,
  y: 420,
  width: 608,
  height: 80,
  depth: 0.14,
}

function lerp(start: number, end: number, amount: number): number {
  return start + (end - start) * amount
}

function roundedRectPoints(
  x: number,
  y: number,
  width: number,
  height: number,
  radius = 12
): readonly Point[] {
  const inset = Math.min(radius, width / 4, height / 3)
  const cornerSteps = 4
  const points: Point[] = [
    [x + inset, y],
    [x + width - inset, y],
  ]
  const addCorner = (centerX: number, centerY: number, start: number) => {
    for (let index = 1; index <= cornerSteps; index += 1) {
      const angle = start + (Math.PI / 2) * (index / cornerSteps)
      points.push([
        centerX + Math.cos(angle) * inset,
        centerY + Math.sin(angle) * inset,
      ])
    }
  }
  addCorner(x + width - inset, y + inset, -Math.PI / 2)
  points.push([x + width, y + height - inset])
  addCorner(x + width - inset, y + height - inset, 0)
  points.push([x + inset, y + height])
  addCorner(x + inset, y + height - inset, Math.PI / 2)
  points.push([x, y + inset])
  addCorner(x + inset, y + inset, Math.PI)
  return points
}

function linePoints(start: Point, end: Point, bend = 0): readonly Point[] {
  const span = end[0] - start[0]
  return [
    start,
    [start[0] + span * 0.32, lerp(start[1], end[1], 0.34) + bend],
    [end[0] - span * 0.32, lerp(start[1], end[1], 0.66) - bend],
    end,
  ]
}

function pointOnPolyline(points: readonly Point[], amount: number): Point {
  if (points.length < 2) return points[0] ?? [0, 0]
  const scaled = Math.max(0, Math.min(0.999999, amount)) * (points.length - 1)
  const index = Math.floor(scaled)
  const progress = scaled - index
  const start = points[index]
  const end = points[index + 1]
  return [lerp(start[0], end[0], progress), lerp(start[1], end[1], progress)]
}

function smoothPath(points: readonly Point[], closed = false): string {
  if (points.length < 2) return ''

  const count = points.length
  const segments = closed ? count : count - 1
  let path = `M ${points[0][0].toFixed(2)} ${points[0][1].toFixed(2)}`

  for (let index = 0; index < segments; index += 1) {
    const point0 = closed
      ? points[(index - 1 + count) % count]
      : points[Math.max(0, index - 1)]
    const point1 = points[index % count]
    const point2 = points[(index + 1) % count]
    const point3 = closed
      ? points[(index + 2) % count]
      : points[Math.min(count - 1, index + 2)]
    const control1: Point = [
      point1[0] + (point2[0] - point0[0]) / 6,
      point1[1] + (point2[1] - point0[1]) / 6,
    ]
    const control2: Point = [
      point2[0] - (point3[0] - point1[0]) / 6,
      point2[1] - (point3[1] - point1[1]) / 6,
    ]
    path += ` C ${control1[0].toFixed(2)} ${control1[1].toFixed(2)} ${control2[0].toFixed(2)} ${control2[1].toFixed(2)} ${point2[0].toFixed(2)} ${point2[1].toFixed(2)}`
  }

  return closed ? `${path} Z` : path
}

function makeDetailPath(
  id: string,
  start: Point,
  end: Point,
  className: string,
  bend = 0
): FluidPath {
  return {
    id,
    points: linePoints(start, end, bend),
    className,
    kind: 'detail',
  }
}

function makeCardLayer(spec: CardSpec): PaperLayer {
  const left = spec.x + 20
  const right = spec.x + spec.width - 20
  const baseline = spec.y + spec.height * 0.56
  return {
    id: spec.id,
    depth: spec.depth,
    center: [spec.x + spec.width / 2, spec.y + spec.height / 2],
    label: spec.label,
    labelPoint: [spec.x + 34, spec.y + 32],
    labelClassName: spec.labelClassName,
    secondaryLabel: spec.secondaryLabel,
    secondaryLabelPoint: spec.secondaryLabel
      ? [spec.x + spec.width / 2, spec.y + spec.height - 22]
      : undefined,
    paths: [
      {
        id:
          spec.label === 'BOUNTY'
            ? 'paper-bounty'
            : `paper-${spec.label.toLowerCase()}`,
        points: roundedRectPoints(spec.x, spec.y, spec.width, spec.height),
        className: spec.surfaceClassName,
        closed: true,
        kind: 'surface',
      },
      makeDetailPath(
        `${spec.label.toLowerCase()}-rule-one`,
        [left, baseline],
        [right, baseline],
        styles.paperRule
      ),
      makeDetailPath(
        `${spec.label.toLowerCase()}-rule-two`,
        [left, baseline + 16],
        [lerp(left, right, 0.82), baseline + 16],
        styles.paperRuleQuiet
      ),
    ],
  }
}

function makeLedgerLayer(spec: LedgerSpec): PaperLayer {
  const firstRuleStart = spec.x + spec.width * 0.22
  const firstRuleEnd = spec.x + spec.width * 0.59
  const secondRuleEnd = spec.x + spec.width * 0.52
  const thirdRuleStart = spec.x + spec.width * 0.66
  return {
    id: spec.id,
    depth: spec.depth,
    center: [spec.x + spec.width / 2, spec.y + spec.height / 2],
    label: 'TOKEN',
    labelPoint: [spec.x + 32, spec.y + 36],
    labelClassName: styles.foundationLabel,
    paths: [
      {
        id: 'token-foundation',
        points: roundedRectPoints(spec.x, spec.y, spec.width, spec.height, 10),
        className: styles.foundationSurface,
        closed: true,
        kind: 'surface',
      },
      makeDetailPath(
        'token-rule-one',
        [firstRuleStart, spec.y + spec.height * 0.45],
        [firstRuleEnd, spec.y + spec.height * 0.45],
        styles.foundationRule
      ),
      makeDetailPath(
        'token-rule-two',
        [firstRuleStart, spec.y + spec.height * 0.65],
        [secondRuleEnd, spec.y + spec.height * 0.65],
        styles.foundationRuleQuiet
      ),
      makeDetailPath(
        'token-rule-three',
        [thirdRuleStart, spec.y + spec.height * 0.45],
        [spec.x + spec.width * 0.93, spec.y + spec.height * 0.45],
        styles.foundationRule
      ),
    ],
  }
}

const PAPER_LAYERS: readonly PaperLayer[] = [
  ...CARD_SPECS.map(makeCardLayer),
  makeLedgerLayer(LEDGER_SPEC),
]

function makeContribution(
  index: number,
  start: Point,
  end: Point,
  bend = 0
): FluidPath {
  return {
    id: `contribution-${String(index).padStart(2, '0')}`,
    points: linePoints(start, end, bend),
    className: styles.contributionPath,
    kind: 'contribution',
  }
}

function makeBundle(
  startX: number,
  startY: [number, number],
  endX: number,
  endY: [number, number],
  startIndex: number,
  count = 5
): readonly FluidPath[] {
  return Array.from({ length: count }, (_, index) => {
    const amount = count === 1 ? 0.5 : index / (count - 1)
    const start: Point = [startX, lerp(startY[0], startY[1], amount)]
    const end: Point = [endX, lerp(endY[0], endY[1], amount)]
    const bend = (index - (count - 1) / 2) * 1.4
    return makeContribution(startIndex + index, start, end, bend)
  })
}

const [BOUNTY, PATCH, MERGED] = CARD_SPECS

const CONTRIBUTION_PATHS: readonly FluidPath[] = [
  ...makeBundle(
    40,
    [142, 214],
    BOUNTY.x + BOUNTY.width * 0.9,
    [BOUNTY.y + 16, BOUNTY.y + BOUNTY.height - 16],
    1
  ),
  ...makeBundle(
    BOUNTY.x + BOUNTY.width * 0.9,
    [BOUNTY.y + 16, BOUNTY.y + BOUNTY.height - 16],
    PATCH.x + PATCH.width * 0.06,
    [PATCH.y + 20, PATCH.y + PATCH.height - 20],
    6
  ),
  ...makeBundle(
    PATCH.x + PATCH.width * 0.94,
    [PATCH.y + 20, PATCH.y + PATCH.height - 20],
    MERGED.x + MERGED.width * 0.06,
    [MERGED.y + 16, MERGED.y + MERGED.height - 16],
    11
  ),
  makeContribution(
    16,
    [40, LEDGER_SPEC.y - 58],
    [VIEWBOX_WIDTH - 40, LEDGER_SPEC.y - 58]
  ),
]

const CONNECTOR_PATHS: readonly FluidPath[] = [
  {
    id: 'connector-bounty',
    points: linePoints(
      [BOUNTY.x + BOUNTY.width * 0.82, BOUNTY.y + BOUNTY.height * 0.78],
      [PATCH.x + PATCH.width * 0.08, PATCH.y + PATCH.height * 0.55],
      -8
    ),
    className: styles.connectorPath,
    kind: 'connector',
  },
  {
    id: 'connector-patch',
    points: linePoints(
      [PATCH.x + PATCH.width * 0.9, PATCH.y + PATCH.height * 0.55],
      [MERGED.x + MERGED.width * 0.18, MERGED.y + MERGED.height * 0.78],
      8
    ),
    className: styles.connectorPath,
    kind: 'connector',
  },
  {
    id: 'connector-merge-token',
    points: linePoints(
      [MERGED.x + MERGED.width * 0.54, MERGED.y + MERGED.height],
      [LEDGER_SPEC.x + LEDGER_SPEC.width * 0.76, LEDGER_SPEC.y],
      -4
    ),
    className: styles.connectorStrong,
    kind: 'connector',
  },
]

const nodePoints: readonly Point[] = [
  ...CONTRIBUTION_PATHS.slice(0, 15).map((path) =>
    pointOnPolyline(path.points, 0.56)
  ),
  ...[0.14, 0.34, 0.54, 0.74, 0.9].map((amount) =>
    pointOnPolyline(CONTRIBUTION_PATHS[15].points, amount)
  ),
  [
    LEDGER_SPEC.x + LEDGER_SPEC.width * 0.76,
    LEDGER_SPEC.y + LEDGER_SPEC.height * 0.45,
  ],
  [
    LEDGER_SPEC.x + LEDGER_SPEC.width * 0.5,
    LEDGER_SPEC.y + LEDGER_SPEC.height * 0.45,
  ],
]

const NODES: readonly {
  id: string
  point: Point
  tone: string
  radius: number
}[] = nodePoints.map((point, index) => ({
  id: `node-${String(index + 1).padStart(2, '0')}`,
  point,
  tone:
    index === 10
      ? styles.nodeClay
      : index === 14 || index === 20
        ? styles.nodeSage
        : styles.nodeInk,
  radius:
    index === 10 || index === 14 || index === 20 ? 6 : index % 4 === 0 ? 4 : 3,
}))

const ALL_PATHS = [
  ...CONTRIBUTION_PATHS,
  ...CONNECTOR_PATHS,
  ...PAPER_LAYERS.flatMap((layer) => layer.paths),
]

function displacementAt(point: Point, pointer: Point, strength: number): Point {
  const deltaX = point[0] - pointer[0]
  const deltaY = point[1] - pointer[1]
  const distance = Math.hypot(deltaX, deltaY)
  if (distance >= POINTER_RADIUS || strength <= 0) return [0, 0]

  const directionX = distance > 0.001 ? deltaX / distance : 0
  const directionY = distance > 0.001 ? deltaY / distance : -1
  const falloff = (1 - distance / POINTER_RADIUS) ** 2
  const verticalLimit = point[1] >= LEDGER_SPEC.y ? 2 : 10
  const amplitude = verticalLimit * falloff * strength
  const curl = Math.sin(point[0] * 0.035 + point[1] * 0.021) * amplitude * 0.18

  return [
    directionX * amplitude - directionY * curl,
    directionY * amplitude + directionX * curl,
  ]
}

type InteractionState = {
  point: [number, number]
  target: [number, number]
  velocity: [number, number]
  strength: number
  strengthTarget: number
  strengthVelocity: number
}

export function ForgeBountyHeroArt() {
  const { t } = useTranslation()
  const wrapperRef = useRef<HTMLDivElement>(null)
  const pathRefs = useRef(new Map<string, SVGPathElement>())
  const restPathRefs = useRef(new Map<string, string>())
  const nodeRefs = useRef(new Map<string, SVGCircleElement>())
  const layerRefs = useRef(new Map<string, SVGGElement>())
  const frameRef = useRef<number | null>(null)
  const enabledRef = useRef(false)
  const stateRef = useRef<InteractionState>({
    point: [VIEWBOX_WIDTH / 2, VIEWBOX_HEIGHT / 2],
    target: [VIEWBOX_WIDTH / 2, VIEWBOX_HEIGHT / 2],
    velocity: [0, 0],
    strength: 0,
    strengthTarget: 0,
    strengthVelocity: 0,
  })

  const resetArtwork = useCallback(() => {
    for (const definition of ALL_PATHS) {
      pathRefs.current
        .get(definition.id)
        ?.setAttribute(
          'd',
          restPathRefs.current.get(definition.id) ??
            smoothPath(definition.points, definition.closed)
        )
    }
    for (const node of NODES) {
      nodeRefs.current.get(node.id)?.removeAttribute('transform')
    }
    for (const layer of PAPER_LAYERS) {
      layerRefs.current.get(layer.id)?.removeAttribute('transform')
    }
    stateRef.current.strength = 0
    stateRef.current.strengthTarget = 0
    stateRef.current.strengthVelocity = 0
    stateRef.current.velocity = [0, 0]
  }, [])

  const runFrame = useCallback(() => {
    frameRef.current = null
    const state = stateRef.current

    state.velocity[0] =
      (state.velocity[0] + (state.target[0] - state.point[0]) * 0.16) * 0.72
    state.velocity[1] =
      (state.velocity[1] + (state.target[1] - state.point[1]) * 0.16) * 0.72
    state.point[0] += state.velocity[0]
    state.point[1] += state.velocity[1]
    state.strengthVelocity =
      (state.strengthVelocity + (state.strengthTarget - state.strength) * 0.2) *
      0.68
    state.strength += state.strengthVelocity

    const settled =
      Math.abs(state.target[0] - state.point[0]) < 0.001 &&
      Math.abs(state.target[1] - state.point[1]) < 0.001 &&
      Math.abs(state.velocity[0]) < 0.001 &&
      Math.abs(state.velocity[1]) < 0.001 &&
      Math.abs(state.strengthTarget - state.strength) < 0.001 &&
      Math.abs(state.strengthVelocity) < 0.001
    if (settled) {
      state.point = [...state.target]
      state.velocity = [0, 0]
      state.strength = state.strengthTarget
      state.strengthVelocity = 0
    }

    for (const definition of ALL_PATHS) {
      const deformedPoints = definition.points.map((point) => {
        const displacement = displacementAt(point, state.point, state.strength)
        return [point[0] + displacement[0], point[1] + displacement[1]] as Point
      })
      pathRefs.current
        .get(definition.id)
        ?.setAttribute('d', smoothPath(deformedPoints, definition.closed))
    }

    for (const node of NODES) {
      const displacement = displacementAt(
        node.point,
        state.point,
        state.strength
      )
      const element = nodeRefs.current.get(node.id)
      if (Math.abs(displacement[0]) + Math.abs(displacement[1]) > 0.001) {
        element?.setAttribute(
          'transform',
          `translate(${displacement[0].toFixed(2)} ${displacement[1].toFixed(2)})`
        )
      } else {
        element?.removeAttribute('transform')
      }
    }

    for (const layer of PAPER_LAYERS) {
      const deltaX = (state.point[0] - layer.center[0]) / VIEWBOX_WIDTH
      const deltaY = (state.point[1] - layer.center[1]) / VIEWBOX_HEIGHT
      const translateX = Math.max(-5, Math.min(5, deltaX * 8 * layer.depth))
      const translateY = Math.max(-4, Math.min(4, deltaY * 7 * layer.depth))
      const rotation = Math.max(-0.8, Math.min(0.8, deltaX * 1.4 * layer.depth))
      const element = layerRefs.current.get(layer.id)
      if (state.strength > 0.001) {
        element?.setAttribute(
          'transform',
          `translate(${(translateX * state.strength).toFixed(2)} ${(translateY * state.strength).toFixed(2)}) rotate(${(rotation * state.strength).toFixed(2)} ${layer.center[0]} ${layer.center[1]})`
        )
      } else {
        element?.removeAttribute('transform')
      }
    }

    if (
      state.strengthTarget === 0 &&
      Math.abs(state.strength) < 0.02 &&
      Math.abs(state.strengthVelocity) < 0.02
    ) {
      resetArtwork()
      return
    }

    if (settled) {
      if (state.strengthTarget === 0) resetArtwork()
      return
    }

    frameRef.current = window.requestAnimationFrame(runFrame)
  }, [resetArtwork])

  const scheduleFrame = useCallback(() => {
    if (frameRef.current === null) {
      frameRef.current = window.requestAnimationFrame(runFrame)
    }
  }, [runFrame])

  const handlePointerMove = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (!enabledRef.current || event.pointerType === 'touch') return
      const bounds = wrapperRef.current?.getBoundingClientRect()
      if (!bounds?.width || !bounds.height) return

      const nextPoint: [number, number] = [
        ((event.clientX - bounds.left) / bounds.width) * VIEWBOX_WIDTH,
        ((event.clientY - bounds.top) / bounds.height) * VIEWBOX_HEIGHT,
      ]
      const state = stateRef.current
      if (state.strength < 0.001) {
        state.point = [...nextPoint]
        state.velocity = [0, 0]
      }
      state.target = nextPoint
      state.strengthTarget = 1
      scheduleFrame()
    },
    [scheduleFrame]
  )

  const handlePointerLeave = useCallback(() => {
    stateRef.current.strengthTarget = 0
    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current)
      frameRef.current = null
    }
    resetArtwork()
  }, [resetArtwork])

  useEffect(() => {
    const element = wrapperRef.current
    if (!element) return
    element.addEventListener('pointerleave', handlePointerLeave)
    return () => element.removeEventListener('pointerleave', handlePointerLeave)
  }, [handlePointerLeave])

  useEffect(() => {
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)')
    const coarsePointer = window.matchMedia('(pointer: coarse)')
    const mobileViewport = window.matchMedia('(max-width: 767px)')
    const mediaQueries = [reducedMotion, coarsePointer, mobileViewport]

    const updateAvailability = () => {
      enabledRef.current = !mediaQueries.some((query) => query.matches)
      if (!enabledRef.current) {
        if (frameRef.current !== null) {
          window.cancelAnimationFrame(frameRef.current)
          frameRef.current = null
        }
        resetArtwork()
      }
    }
    const handleVisibility = () => {
      if (document.visibilityState === 'hidden') {
        if (frameRef.current !== null) {
          window.cancelAnimationFrame(frameRef.current)
          frameRef.current = null
        }
        resetArtwork()
      }
    }

    updateAvailability()
    for (const query of mediaQueries) {
      query.addEventListener('change', updateAvailability)
    }
    document.addEventListener('visibilitychange', handleVisibility)

    return () => {
      for (const query of mediaQueries) {
        query.removeEventListener('change', updateAvailability)
      }
      document.removeEventListener('visibilitychange', handleVisibility)
      if (frameRef.current !== null) {
        window.cancelAnimationFrame(frameRef.current)
        frameRef.current = null
      }
      resetArtwork()
    }
  }, [resetArtwork])

  const renderPath = (definition: FluidPath) => {
    const anchor = definition.points[Math.floor(definition.points.length / 2)]
    const restPath = smoothPath(definition.points, definition.closed)
    restPathRefs.current.set(definition.id, restPath)
    return (
      <path
        key={definition.id}
        ref={(element) => {
          if (element) pathRefs.current.set(definition.id, element)
          else pathRefs.current.delete(definition.id)
        }}
        d={restPath}
        className={definition.className}
        data-fluid-id={definition.id}
        data-fluid-path={definition.kind}
        data-anchor-x={anchor[0]}
        data-anchor-y={anchor[1]}
        vectorEffect='non-scaling-stroke'
      />
    )
  }

  return (
    <div
      ref={wrapperRef}
      className={styles.root}
      onPointerMove={handlePointerMove}
      onPointerLeave={handlePointerLeave}
      data-forge-bounty-art='interactive'
    >
      <svg
        viewBox={`0 0 ${VIEWBOX_WIDTH} ${VIEWBOX_HEIGHT}`}
        className={styles.artwork}
        role='img'
        aria-labelledby='forge-bounty-art-title forge-bounty-art-description'
      >
        <title id='forge-bounty-art-title'>
          {t('Open-source bounty delivery field')}
        </title>
        <desc id='forge-bounty-art-description'>
          {t(
            'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.'
          )}
        </desc>

        <g className={styles.contributionField} aria-hidden='true'>
          {CONTRIBUTION_PATHS.map(renderPath)}
          {CONNECTOR_PATHS.map(renderPath)}
        </g>

        {PAPER_LAYERS.map((layer) => (
          <g
            key={layer.id}
            ref={(element) => {
              if (element) layerRefs.current.set(layer.id, element)
              else layerRefs.current.delete(layer.id)
            }}
            className={styles.paperLayer}
            data-layer-id={layer.id}
            aria-hidden='true'
          >
            {layer.paths.map(renderPath)}
            <text
              x={layer.labelPoint[0]}
              y={layer.labelPoint[1]}
              className={[styles.label, layer.labelClassName]
                .filter(Boolean)
                .join(' ')}
            >
              {layer.label}
            </text>
            {layer.secondaryLabel && layer.secondaryLabelPoint ? (
              <text
                x={layer.secondaryLabelPoint[0]}
                y={layer.secondaryLabelPoint[1]}
                className={styles.secondaryLabel}
              >
                {layer.secondaryLabel}
              </text>
            ) : null}
          </g>
        ))}

        <g aria-hidden='true'>
          {NODES.map((node) => (
            <circle
              key={node.id}
              ref={(element) => {
                if (element) nodeRefs.current.set(node.id, element)
                else nodeRefs.current.delete(node.id)
              }}
              cx={node.point[0]}
              cy={node.point[1]}
              r={node.radius}
              className={node.tone}
              data-fluid-id={node.id}
              data-fluid-node='true'
              data-anchor-x={node.point[0]}
              data-anchor-y={node.point[1]}
              vectorEffect='non-scaling-stroke'
            />
          ))}
        </g>
      </svg>
    </div>
  )
}
