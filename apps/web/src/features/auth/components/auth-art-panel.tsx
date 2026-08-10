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
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

const ART_WIDTH = 720
const ART_HEIGHT = 900

const AUTH_ARTWORK = (
  <g className='auth-artwork' aria-hidden='true'>
    <path
      className='auth-art-core'
      d='M 352 383 C 386 360 438 371 462 406 C 486 442 466 486 428 504 C 388 522 342 503 325 464 C 311 432 323 401 352 383 Z'
    />
    <path
      className='auth-art-left-gesture'
      d='M -32 510 C 34 486 91 454 148 417 C 200 383 246 358 296 366 C 319 369 338 381 349 398 C 358 412 352 428 338 434 C 321 441 303 429 286 423 C 260 414 232 425 203 445 C 151 482 103 526 45 551 C 15 565 -11 565 -32 554 Z'
    />
    <path
      className='auth-art-right-gesture'
      d='M 752 548 C 699 534 650 510 605 484 C 568 462 535 449 505 455 C 483 459 467 474 461 491 C 457 504 464 516 477 519 C 491 522 503 511 517 503 C 538 491 560 498 584 514 C 625 541 661 575 709 593 C 729 601 744 599 752 588 Z'
    />
    <path
      className='auth-art-contour'
      d='M 148 503 C 194 476 230 454 267 448 C 292 444 312 450 330 465 M 489 503 C 520 503 548 514 575 534 C 596 550 614 556 636 554'
    />
    <circle className='auth-art-clay' cx='432' cy='466' r='9' />
  </g>
)

export function AuthArtPanel() {
  const { t } = useTranslation()
  const [activeInsight, setActiveInsight] = useState(0)
  const insights = [
    {
      label: t('Authentication'),
      title: t('Build in public. Earn access.'),
      body: t('Verified open-source work becomes usable model access.'),
    },
    {
      label: t('Security'),
      title: t('Security'),
      body: t('Protect login and registration with Cloudflare Turnstile'),
    },
    {
      label: t('API.LMM.BEST / TOKEN SERVICE'),
      title: t('API.LMM.BEST / TOKEN SERVICE'),
      body: t('stable access layer'),
    },
  ]
  const selectedInsight = insights[activeInsight] ?? insights[0]

  return (
    <aside
      aria-label={t('LMM / OPEN-SOURCE BOUNTY FIELD')}
      className='relative h-full min-h-0 overflow-visible p-4'
    >
      <div className='auth-art-surface pointer-events-auto absolute inset-4 overflow-hidden rounded-none border [border-color:var(--art-border)] bg-[var(--art-surface)] text-[var(--art-ink)] select-none'>
        <svg
          viewBox={`0 0 ${ART_WIDTH} ${ART_HEIGHT}`}
          preserveAspectRatio='xMidYMid meet'
          focusable='false'
          aria-hidden='true'
          className='h-full w-full'
          xmlns='http://www.w3.org/2000/svg'
        >
          {AUTH_ARTWORK}
        </svg>

        <div className='auth-art-overlay'>
          <div
            id='auth-art-insight-panel'
            role='tabpanel'
            aria-labelledby={`auth-art-tab-${activeInsight}`}
            aria-live='polite'
            className='auth-art-overlay-card'
          >
            <div className='auth-art-overlay-index'>
              0{activeInsight + 1} / 03
            </div>
            <h2 className='auth-art-overlay-title'>{selectedInsight.title}</h2>
            <p className='auth-art-overlay-copy'>{selectedInsight.body}</p>
          </div>

          <div
            className='auth-art-tabs'
            role='tablist'
            aria-label={t('Authentication')}
          >
            {insights.map((insight, index) => (
              <button
                id={`auth-art-tab-${index}`}
                key={insight.label}
                type='button'
                role='tab'
                aria-controls='auth-art-insight-panel'
                aria-selected={activeInsight === index}
                className='auth-art-tab'
                data-active={activeInsight === index}
                onClick={() => setActiveInsight(index)}
              >
                <span className='auth-art-tab-number'>0{index + 1}</span>
                <span className='auth-art-tab-label'>{insight.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </aside>
  )
}
