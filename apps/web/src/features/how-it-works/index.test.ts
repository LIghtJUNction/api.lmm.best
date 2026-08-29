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
import { readFileSync } from 'node:fs'
import { describe, test } from 'node:test'

const pageSource = readFileSync(new URL('./index.tsx', import.meta.url), 'utf8')
const routeSource = readFileSync(
  new URL('../../routes/how-it-works/index.tsx', import.meta.url),
  'utf8'
)
const footerSource = readFileSync(
  new URL('../../components/layout/components/footer.tsx', import.meta.url),
  'utf8'
)

describe('How it works public page', () => {
  test('registers an independently reachable file route', () => {
    assert.match(routeSource, /createFileRoute\('\/how-it-works\/'\)/)
    assert.match(routeSource, /component: HowItWorks/)
  })

  test('uses the Forge public shell and existing editorial layout', () => {
    assert.match(pageSource, /ForgePublicShell/)
    assert.match(pageSource, /t\('How it works'\)/)
    assert.match(pageSource, /to='\/challenges'/)
    assert.match(pageSource, /to='\/guide'/)
  })

  test('points the homepage footer at the dedicated page', () => {
    assert.match(footerSource, /text: t\('How it works'\)/)
    assert.match(footerSource, /href: '\/how-it-works'/)
    assert.doesNotMatch(footerSource, /href: '\/#workflow'/)
  })
})
