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
export type AssistantSetupPlatform = 'windows' | 'macos' | 'linux'

export type CCSwitchInstallGuide = {
  artifact: string
  command: string | null
}

function quotePOSIX(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`
}

function quotePowerShell(value: string): string {
  return `'${value.replaceAll("'", "''")}'`
}

export function getClaudeInstallCommand(
  platform: AssistantSetupPlatform
): string {
  if (platform === 'windows') return 'winget install Anthropic.ClaudeCode'
  if (platform === 'macos') return 'brew install --cask claude-code'
  return 'curl -fsSL https://claude.ai/install.sh | bash'
}

export function getClaudeSessionCommand(
  platform: AssistantSetupPlatform,
  rootUrl: string,
  model: string
): string {
  const normalizedRoot = rootUrl.replace(/\/+$/, '')
  const normalizedModel = model.trim() || '<MODEL_ID>'
  if (platform === 'windows') {
    return [
      `$env:ANTHROPIC_BASE_URL=${quotePowerShell(normalizedRoot)}`,
      `$env:ANTHROPIC_AUTH_TOKEN='<YOUR_API_KEY>'`,
      `$env:ANTHROPIC_MODEL=${quotePowerShell(normalizedModel)}`,
      'claude',
    ].join('\n')
  }

  return [
    `export ANTHROPIC_BASE_URL=${quotePOSIX(normalizedRoot)}`,
    `export ANTHROPIC_AUTH_TOKEN='<YOUR_API_KEY>'`,
    `export ANTHROPIC_MODEL=${quotePOSIX(normalizedModel)}`,
    'claude',
  ].join('\n')
}

export function getCCSwitchInstallGuide(
  platform: AssistantSetupPlatform
): CCSwitchInstallGuide {
  if (platform === 'windows') {
    return {
      artifact: 'CC-Switch-v{version}-Windows.msi',
      command: null,
    }
  }
  if (platform === 'macos') {
    return {
      artifact: 'CC-Switch-v{version}-macOS.dmg',
      command: 'brew install --cask cc-switch',
    }
  }
  return {
    artifact: 'CC-Switch-v{version}-Linux-{architecture}.AppImage',
    command: [
      '# Arch Linux',
      'paru -S cc-switch-bin',
      '',
      '# Debian / Ubuntu (after downloading the .deb)',
      'sudo apt install ./CC-Switch-v*-Linux-*.deb',
      '',
      '# Universal AppImage (after downloading it)',
      'chmod +x CC-Switch-v*-Linux-*.AppImage',
      './CC-Switch-v*-Linux-*.AppImage',
    ].join('\n'),
  }
}

export function getCCSwitchClaudeProviderJSON(
  rootUrl: string,
  model: string
): string {
  return JSON.stringify(
    {
      env: {
        ANTHROPIC_AUTH_TOKEN: '<YOUR_API_KEY>',
        ANTHROPIC_BASE_URL: rootUrl.replace(/\/+$/, ''),
        ANTHROPIC_MODEL: model.trim() || '<MODEL_ID>',
      },
    },
    null,
    2
  )
}
