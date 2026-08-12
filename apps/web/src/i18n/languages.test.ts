import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import {
  normalizeInterfaceLanguage,
  toIntlLocale,
} from './languages'

describe('interface language locale conversion', () => {
  test('keeps the internal Chinese codes separate from Intl locale tags', () => {
    assert.equal(normalizeInterfaceLanguage('zh-CN'), 'zhCN')
    assert.equal(normalizeInterfaceLanguage('zh-TW'), 'zhTW')
    assert.equal(toIntlLocale('zhCN'), 'zh-CN')
    assert.equal(toIntlLocale('zhTW'), 'zh-TW')
  })

  test('returns a safe fallback for malformed Intl locale values', () => {
    assert.equal(toIntlLocale('zh_CN'), undefined)
    assert.equal(toIntlLocale('???'), undefined)
    assert.equal(toIntlLocale(null), undefined)
  })
})
