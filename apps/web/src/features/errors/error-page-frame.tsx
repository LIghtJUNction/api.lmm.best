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
*/
import { LmmBrandMark } from '@/components/lmm-brand-mark'

import './error-page-frame.css'

type ErrorPageFrameProps = {
  status?: string | number
  title: React.ReactNode
  description: React.ReactNode
  actions?: React.ReactNode
  note?: React.ReactNode
  showStatus?: boolean
}

export function ErrorPageFrame(props: ErrorPageFrameProps) {
  return (
    <main className='error-editorial min-h-svh'>
      <div className='mx-auto grid min-h-svh max-w-6xl items-center gap-12 px-5 py-16 md:grid-cols-[minmax(0,0.9fr)_minmax(18rem,0.72fr)] md:px-10'>
        <section>
          <div className='mb-12 flex items-center gap-2 text-sm font-semibold'>
            <LmmBrandMark className='size-7' title='LMM Forge' />
            <span>LMM Forge</span>
          </div>
          <p className='error-editorial-kicker mb-5'>System note</p>
          {props.showStatus !== false && (
            <p
              className='error-editorial-status mb-8'
              aria-label={String(props.status)}
            >
              {props.status}
            </p>
          )}
          <h1 className='max-w-2xl font-serif text-4xl leading-tight font-normal md:text-6xl'>
            {props.title}
          </h1>
          <p className='error-editorial-muted mt-5 max-w-xl text-base leading-7'>
            {props.description}
          </p>
          {props.note && (
            <p className='error-editorial-muted mt-4 max-w-xl text-sm leading-6'>
              {props.note}
            </p>
          )}
          {props.actions && (
            <div className='mt-8 flex flex-wrap gap-3'>{props.actions}</div>
          )}
        </section>

        <aside className='hidden md:block' aria-hidden='true'>
          <svg
            className='error-editorial-art'
            viewBox='0 0 520 420'
            preserveAspectRatio='xMidYMid meet'
            focusable='false'
            xmlns='http://www.w3.org/2000/svg'
          >
            <path
              className='error-art-carrier'
              d='M 112 76 C 166 38 242 63 302 56 C 375 48 432 85 426 151 C 420 213 462 263 425 323 C 389 382 310 374 251 356 C 191 338 126 361 92 310 C 59 259 83 213 73 166 C 66 126 78 98 112 76 Z'
            />
            <path
              className='error-art-gesture'
              d='M -24 286 C 46 266 93 230 150 194 C 201 161 249 147 286 164 C 310 175 321 195 312 211 C 302 227 278 224 255 215 C 227 205 199 218 166 243 C 118 280 77 320 25 335 C -4 343 -21 331 -24 316 Z'
            />
            <path
              className='error-art-contour'
              d='M 162 278 C 202 252 234 237 265 239 C 286 240 303 248 319 261 M 347 146 C 374 153 395 167 409 185'
            />
            <circle className='error-art-clay' cx='350' cy='294' r='13' />
          </svg>
        </aside>
      </div>
    </main>
  )
}
