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
import { test } from 'node:test'

import { sanitizeWebPreviewUrl } from './web-preview-url'

test('sanitizeWebPreviewUrl accepts absolute HTTP URLs', () => {
  assert.equal(
    sanitizeWebPreviewUrl(' https://example.com/docs?q=1 '),
    'https://example.com/docs?q=1'
  )
})

test('sanitizeWebPreviewUrl rejects executable and inline-document schemes', () => {
  for (const value of [
    'javascript:alert(document.domain)',
    'data:text/html,<script>alert(1)</script>',
    'vbscript:msgbox(1)',
  ]) {
    assert.equal(sanitizeWebPreviewUrl(value), undefined)
  }
})

test('sanitizeWebPreviewUrl rejects relative and malformed URLs', () => {
  assert.equal(sanitizeWebPreviewUrl('/same-origin-admin'), undefined)
  assert.equal(sanitizeWebPreviewUrl('not a url'), undefined)
})
