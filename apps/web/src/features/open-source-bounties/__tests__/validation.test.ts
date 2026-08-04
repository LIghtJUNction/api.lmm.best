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
  type BountyDraftValidationInput,
  validateBountyDraft,
} from '../validation'

const VALID_DRAFT: BountyDraftValidationInput = {
  repositoryUrl: 'https://github.com/LIghtJUNction/api.lmm.best',
  title: 'Fix missing translations in the bounty workflow',
  description:
    'Find and correct reproducible untranslated or incorrectly translated interface text.',
  rules:
    'Link a valid Issue and focused pull request, update every supported locale, and include passing verification.',
  rewardAmount: 50,
  rewardSlots: 1,
}

describe('bounty draft validation', () => {
  test('accepts a complete draft with a canonical GitHub repository URL', () => {
    assert.deepEqual(validateBountyDraft(VALID_DRAFT), {})
  })

  test('reports every invalid field with a specific message', () => {
    const errors = validateBountyDraft({
      repositoryUrl: 'http://example.com/not-github',
      title: 'bug',
      description: 'too short',
      rules: 'too short',
      rewardAmount: 0,
      rewardSlots: 1.5,
    })

    assert.deepEqual(Object.keys(errors), [
      'repositoryUrl',
      'title',
      'description',
      'rules',
      'rewardAmount',
      'rewardSlots',
    ])
    for (const message of Object.values(errors)) {
      assert.ok(message)
      assert.equal(message.endsWith('.'), true)
    }
  })

  test('rejects repository pages and reward slot values outside the server limits', () => {
    assert.equal(
      validateBountyDraft({
        ...VALID_DRAFT,
        repositoryUrl:
          'https://github.com/LIghtJUNction/api.lmm.best/issues/15',
      }).repositoryUrl,
      'Enter a GitHub repository URL in the format https://github.com/owner/repository.'
    )
    assert.equal(
      validateBountyDraft({ ...VALID_DRAFT, rewardSlots: 101 }).rewardSlots,
      'Reward slots must be a whole number between 1 and 100.'
    )
  })
})
