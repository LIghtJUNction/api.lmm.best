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

import { getClaudeInstallCommand, getClaudeSessionCommand } from './setup-guide'

describe('assistant setup guide', () => {
  test('uses current official install commands for each platform', () => {
    assert.equal(
      getClaudeInstallCommand('windows'),
      'winget install Anthropic.ClaudeCode'
    )
    assert.equal(
      getClaudeInstallCommand('macos'),
      'brew install --cask claude-code'
    )
    assert.equal(
      getClaudeInstallCommand('linux'),
      'curl -fsSL https://claude.ai/install.sh | bash'
    )
  })

  test('builds PowerShell and POSIX session-only gateway configuration', () => {
    assert.equal(
      getClaudeSessionCommand(
        'windows',
        'https://api.lmm.best/',
        'deepseek-v4-flash'
      ),
      [
        "$env:ANTHROPIC_BASE_URL='https://api.lmm.best'",
        "$env:ANTHROPIC_AUTH_TOKEN='<YOUR_API_KEY>'",
        "$env:ANTHROPIC_MODEL='deepseek-v4-flash'",
        'claude',
      ].join('\n')
    )
    assert.equal(
      getClaudeSessionCommand('linux', 'https://api.lmm.best', "model'o"),
      [
        "export ANTHROPIC_BASE_URL='https://api.lmm.best'",
        "export ANTHROPIC_AUTH_TOKEN='<YOUR_API_KEY>'",
        "export ANTHROPIC_MODEL='model'\"'\"'o'",
        'claude',
      ].join('\n')
    )
  })
})
