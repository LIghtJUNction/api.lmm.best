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
import { useTranslation } from 'react-i18next'

import styles from './forge-bounty-hero-art.module.css'

const VIEWBOX_WIDTH = 720
const VIEWBOX_HEIGHT = 560

export function ForgeBountyHeroArt() {
  const { t } = useTranslation()

  return (
    <div className={styles.root} data-forge-bounty-art='editorial'>
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

        <g className={styles.anthropicArtwork} aria-hidden='true'>
          <path
            className={styles.ivoryCore}
            d='M 329 222 C 361 197 412 205 440 238 C 467 270 452 315 416 336 C 377 358 331 344 309 307 C 291 276 301 244 329 222 Z'
          />
          <path
            className={styles.gestureLeft}
            d='M -34 374 C 33 350 96 320 154 286 C 202 258 245 235 292 230 C 313 228 335 237 348 252 C 357 263 354 275 344 283 C 330 294 310 289 292 285 C 264 279 235 291 206 311 C 157 345 106 391 46 414 C 15 426 -10 427 -34 418 Z'
          />
          <path
            className={styles.gestureRight}
            d='M 754 395 C 702 383 650 362 604 337 C 564 315 531 300 499 301 C 481 302 466 312 459 326 C 453 337 458 348 468 353 C 481 359 495 352 508 345 C 529 334 552 340 574 354 C 614 379 650 413 698 433 C 724 444 744 444 754 438 Z'
          />
          <path
            className={styles.gestureContour}
            d='M 166 350 C 205 328 235 309 271 298 C 290 292 307 294 321 303 M 493 336 C 517 338 542 350 567 369 C 585 383 601 390 620 391'
          />
          <circle className={styles.clayMark} cx='405' cy='310' r='9' />
        </g>
      </svg>
    </div>
  )
}
