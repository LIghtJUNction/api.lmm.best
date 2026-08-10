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

import type { FileUIPart } from 'ai'

import {
  formatMessageForAPI,
  createUserMessage,
} from '../message/message-utils'
import { preparePlaygroundSubmission } from './playground-attachment-utils'

describe('playground attachments', () => {
  test('turns UTF-8 text files into explicit prompt context', () => {
    const submission = preparePlaygroundSubmission({
      text: 'Review this',
      files: [
        {
          type: 'file',
          filename: 'notes.md',
          mediaType: 'text/markdown',
          url: 'data:text/markdown;base64,IyBIZWxsbw==',
        } satisfies FileUIPart,
      ],
    })

    assert.match(submission.text, /Review this/)
    assert.match(submission.text, /Attached file: notes\.md/)
    assert.match(submission.text, /# Hello/)
    assert.deepEqual(submission.attachments, [
      { kind: 'text', name: 'notes.md', mediaType: 'text/markdown' },
    ])
  })

  test('keeps image data URLs as multimodal chat content', () => {
    const imageURL = 'data:image/png;base64,iVBORw0KGgo='
    const submission = preparePlaygroundSubmission({
      files: [
        {
          type: 'file',
          filename: 'diagram.png',
          mediaType: 'image/png',
          url: imageURL,
        } satisfies FileUIPart,
      ],
    })
    const message = createUserMessage(
      submission.text,
      1,
      submission.attachments
    )

    assert.deepEqual(formatMessageForAPI(message), {
      role: 'user',
      content: [
        { type: 'text', text: '' },
        { type: 'image_url', image_url: { url: imageURL } },
      ],
    })
  })

  test('rejects opaque binary files instead of pretending to upload them', () => {
    assert.throws(
      () =>
        preparePlaygroundSubmission({
          files: [
            {
              type: 'file',
              filename: 'archive.zip',
              mediaType: 'application/zip',
              url: 'data:application/zip;base64,UEsDBA==',
            } satisfies FileUIPart,
          ],
        }),
      /Unsupported attachment type/
    )
  })
})
