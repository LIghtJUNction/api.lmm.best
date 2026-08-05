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
import type { SVGProps } from 'react'

import { cn } from '@/lib/utils'

export const LMM_BRAND_NAME = 'LMM Forge'

type LmmBrandMarkProps = SVGProps<SVGSVGElement> & {
  title?: string
}

/**
 * Three loose input paths becoming one stable route: an original mark for
 * lmm.best's role as an AI API control plane.
 */
export function LmmBrandMark({
  className,
  title,
  ...props
}: LmmBrandMarkProps) {
  return (
    <svg
      viewBox='0 0 56 56'
      xmlns='http://www.w3.org/2000/svg'
      role={title ? 'img' : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : true}
      focusable='false'
      className={cn('shrink-0 overflow-visible', className)}
      {...props}
    >
      <path
        d='M8.2 14.1C12.8 6.8 23.6 4.7 34.4 7.1c9.7 2.1 15.4 9.8 13.4 20.8-1.7 9.4-7.6 18-18.2 20.2-9.2 1.9-19.8-2.4-22.1-11.5-1.8-7.2-3.5-15.9.7-22.5Z'
        fill='#BCD1CA'
        stroke='#141413'
        strokeWidth='2.2'
        strokeLinecap='round'
        strokeLinejoin='round'
      />
      <path
        d='M15.4 20.1c3.8-5.1 11.4-7.3 18-4.9 6.1 2.2 9.4 7.7 7.8 13.9-1.9 7.3-9.2 12-16.5 10.7-6.1-1-11.3-5.4-11.8-11.1-.3-3.2.6-6.3 2.5-8.6Z'
        fill='#FAF9F5'
      />
      <g
        fill='none'
        stroke='#141413'
        strokeWidth='3.2'
        strokeLinecap='round'
        strokeLinejoin='round'
      >
        <path d='M13.4 19.1c6.4-.8 8.6 1.8 11.4 6.3 2.3 3.7 5.5 4.4 9.4 4.3' />
        <path d='M12.1 28.4c6.1.1 8.6-.1 12.7-3 4.7-3.3 6.7-2.7 10.2-.4' />
        <path d='M14.1 37.2c5.4-.9 7.8-3.5 10.7-7.8 2.4-3.6 5.9-4.4 9.8-4.3' />
        <path d='M34.4 27.3c3.4.1 6.1.2 9.2-.7' />
      </g>
      <g fill='#141413'>
        <circle cx='12.8' cy='19.2' r='2.4' />
        <circle cx='11.8' cy='28.4' r='2.4' />
        <circle cx='13.5' cy='37.2' r='2.4' />
        <circle cx='44.1' cy='26.5' r='2.7' />
      </g>
    </svg>
  )
}
