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

import { HeaderLogo } from '@/components/layout/components/header-logo'

import { normalizePointerPosition } from '../lib/hero-parallax'

const POINTER_TRAVEL = 8
const SPRING = { damping: 27, mass: 1, stiffness: 180 }

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
      className='landing-animate-fade-up mx-auto w-full max-w-md border-2 border-[#141413] bg-[#D97757] p-5 opacity-0 [animation-delay:240ms] sm:p-7 lg:mr-8 lg:max-w-sm lg:-translate-y-3 lg:justify-self-end lg:rounded-[42%_58%_45%_55%/8%_12%_88%_92%]'
    >
      <motion.div style={{ y: shouldReduceMotion ? 0 : scrollY }}>
        <motion.div
          style={{
            x: shouldReduceMotion ? 0 : springX,
            y: shouldReduceMotion ? 0 : springY,
          }}
          className='will-change-transform'
        >
          <div className='ml-auto w-[82%] overflow-hidden rounded-[52%_48%_60%_40%/43%_58%_42%_57%] border-2 border-[#141413] bg-[#BCD1CA]'>
            <HeaderLogo
              src='/logo.png'
              width={512}
              height={512}
              alt=''
              loading={false}
              logoLoaded
              className='aspect-square size-full rounded-none object-cover transition-none'
              decoding='async'
              fetchPriority='high'
            />
          </div>
        </motion.div>
      </motion.div>
      <figcaption className='mt-5 max-w-64 border-t border-[#141413] pt-3 text-xs leading-5 font-medium'>
        {caption}
      </figcaption>
    </figure>
  )
}
