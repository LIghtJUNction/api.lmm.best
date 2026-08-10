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

import {
  getInputControlState,
  getSubmittableInputText,
} from './input-control-utils'

describe('playground input controls', () => {
  test('allows an attachment-only multimodal request', () => {
    assert.equal(getSubmittableInputText({ text: '', files: [{}] }), '')
    assert.equal(
      getInputControlState({
        attachmentCount: 1,
        groups: [{ label: 'Default', value: 'default', ratio: 1 }],
        hasStopHandler: true,
        models: [{ label: 'Vision', value: 'vision' }],
        text: '',
      }).canSubmit,
      true
    )
  })

  test('keeps an empty input disabled when it has no attachments', () => {
    assert.equal(getSubmittableInputText({ text: '', files: [] }), null)
  })
})
