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
import { describe, test } from 'node:test'

import { normalizePointerPosition } from './hero-parallax'

describe('hero parallax pointer normalization', () => {
  test('maps the bounds and midpoint to a normalized range', () => {
    assert.equal(normalizePointerPosition(20, 20, 100), -1)
    assert.equal(normalizePointerPosition(70, 20, 100), 0)
    assert.equal(normalizePointerPosition(120, 20, 100), 1)
  })

  test('clamps out-of-bounds positions and handles empty bounds', () => {
    assert.equal(normalizePointerPosition(-100, 20, 100), -1)
    assert.equal(normalizePointerPosition(500, 20, 100), 1)
    assert.equal(normalizePointerPosition(20, 20, 0), 0)
  })
})
