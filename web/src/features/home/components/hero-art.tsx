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
import {
  motion,
  useMotionValue,
  useReducedMotion,
  useScroll,
  useSpring,
  useTransform,
} from 'motion/react'
import { useEffect, useRef, type PointerEvent } from 'react'

import { Skeleton } from '@/components/ui/skeleton'

import { normalizePointerPosition } from '../lib/hero-parallax'

const POINTER_TRAVEL = 8
const SPRING = { damping: 27, mass: 1, stiffness: 180 }
const HERO_ART_SHELL_CLASS = 'mx-auto w-full max-w-[34rem] lg:justify-self-end'
const HERO_ART_MEDIA_CLASS =
  'overflow-hidden bg-[#BCD1CA] [clip-path:polygon(8%_4%,88%_0%,100%_13%,96%_86%,82%_100%,9%_95%,0%_78%,3%_16%)]'
const HERO_ART_CAPTION_CLASS =
  'mt-5 grid grid-cols-[3rem_1fr] items-start gap-3 text-[0.6875rem] leading-5 font-semibold tracking-[0.09em] uppercase text-[#141413]/72 dark:text-[#FAF9F5]/72'

interface HeroArtProps {
  caption: string
}

export function HeroArt({ caption }: HeroArtProps) {
  const figureRef = useRef<HTMLElement>(null)
  const shouldReduceMotion = useReducedMotion()
  const pointerX = useMotionValue(0)
  const pointerY = useMotionValue(0)
  const springX = useSpring(pointerX, SPRING)
  const springY = useSpring(pointerY, SPRING)
  const { scrollYProgress } = useScroll({
    target: figureRef,
    offset: ['start end', 'end start'],
  })
  const scrollY = useTransform(
    scrollYProgress,
    [0, 1],
    shouldReduceMotion ? [0, 0] : [-6, 6]
  )

  const resetPointer = () => {
    pointerX.set(0)
    pointerY.set(0)
  }

  useEffect(() => {
    if (shouldReduceMotion) {
      pointerX.set(0)
      pointerY.set(0)
    }
  }, [pointerX, pointerY, shouldReduceMotion])

  const handlePointerMove = (event: PointerEvent<HTMLElement>) => {
    if (
      shouldReduceMotion ||
      event.pointerType !== 'mouse' ||
      !window.matchMedia('(pointer: fine)').matches
    ) {
      resetPointer()
      return
    }

    const bounds = event.currentTarget.getBoundingClientRect()
    pointerX.set(
      normalizePointerPosition(event.clientX, bounds.left, bounds.width) *
        POINTER_TRAVEL
    )
    pointerY.set(
      normalizePointerPosition(event.clientY, bounds.top, bounds.height) *
        POINTER_TRAVEL
    )
  }

  return (
    <figure
      ref={figureRef}
      onPointerMove={handlePointerMove}
      onPointerLeave={resetPointer}
      className={`landing-animate-fade-up opacity-0 [animation-delay:240ms] ${HERO_ART_SHELL_CLASS}`}
    >
      <motion.div
        style={{ y: shouldReduceMotion ? 0 : scrollY }}
        className={HERO_ART_MEDIA_CLASS}
      >
        <motion.div
          style={{
            x: shouldReduceMotion ? 0 : springX,
            y: shouldReduceMotion ? 0 : springY,
          }}
          className='will-change-transform'
        >
          <picture className='block'>
            <source
              media='(max-width: 639px)'
              srcSet='/gateway-orchestration-640.webp 640w, /gateway-orchestration-960.webp 960w'
              sizes='calc(100vw - 40px)'
              type='image/webp'
            />
            <img
              src='/gateway-orchestration-960.webp'
              srcSet='/gateway-orchestration-640.webp 640w, /gateway-orchestration-960.webp 960w, /gateway-orchestration-1448.webp 1448w'
              sizes='(min-width: 1024px) 520px, 576px'
              width={1448}
              height={1086}
              alt=''
              className='aspect-4/3 w-full scale-[1.015] object-cover'
              decoding='async'
              loading='eager'
              fetchPriority='high'
            />
          </picture>
        </motion.div>
      </motion.div>
      <figcaption className={HERO_ART_CAPTION_CLASS}>
        <span
          className='mt-2 h-0.5 w-full bg-[#141413] dark:bg-[#FAF9F5]'
          aria-hidden='true'
        />
        <span>{caption}</span>
      </figcaption>
    </figure>
  )
}

export function HeroArtSkeleton() {
  return (
    <div className={HERO_ART_SHELL_CLASS} aria-hidden='true'>
      <div className={HERO_ART_MEDIA_CLASS}>
        <Skeleton className='aspect-4/3 w-full rounded-none bg-[#BCD1CA]/60' />
      </div>
      <div className={HERO_ART_CAPTION_CLASS}>
        <Skeleton className='mt-2 h-0.5 w-full rounded-none bg-[#141413]/15' />
        <Skeleton className='h-5 w-56 max-w-[75%] bg-[#141413]/15' />
      </div>
    </div>
  )
}
