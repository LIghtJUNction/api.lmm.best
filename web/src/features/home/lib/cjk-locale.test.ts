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

import { isCjkLocale } from './cjk-locale'

describe('isCjkLocale', () => {
  test('recognizes project and conventional Chinese/Japanese locale codes', () => {
    const locales = ['zhCN', 'zhTW', 'zh', 'zh-CN', 'zh-Hant-TW', 'ja', 'ja-JP']
    for (const locale of locales) {
      assert.equal(isCjkLocale(locale), true, locale)
    }
  })

  test('does not misclassify unrelated or extended locale-like strings', () => {
    const locales = [
      'en',
      'fr',
      'zhCN-extra',
      'zhTWfoo',
      'japanese',
      'zh-',
      'ja-',
    ]
    for (const locale of locales) {
      assert.equal(isCjkLocale(locale), false, locale)
    }
  })
})
