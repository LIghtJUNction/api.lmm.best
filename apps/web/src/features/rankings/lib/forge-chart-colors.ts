/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

/**
 * Resolve a Forge color token for canvas-backed charts. CSS variables are the
 * source of truth; the small resolver is needed because VChart receives
 * concrete color strings rather than CSS declarations.
 */
export function readForgeColor(token: string, theme?: string) {
  if (typeof document === 'undefined') return `var(${token})`

  const surface = document.querySelector<HTMLElement>(
    theme === 'dark' ? '.dark .forge-surface, .forge-surface' : '.forge-surface'
  )
  const scope = surface ?? document.documentElement
  const value = getComputedStyle(scope).getPropertyValue(token).trim()
  return value || `var(${token})`
}

export const FORGE_VENDOR_COLOR_TOKENS: Record<string, string> = {
  OpenAI: '--forge-vendor-openai',
  Anthropic: '--forge-vendor-anthropic',
  Google: '--forge-vendor-google',
  DeepSeek: '--forge-vendor-deepseek',
  Alibaba: '--forge-vendor-alibaba',
  xAI: '--forge-vendor-xai',
  Meta: '--forge-vendor-meta',
  Moonshot: '--forge-vendor-moonshot',
  Zhipu: '--forge-vendor-zhipu',
  Mistral: '--forge-vendor-mistral',
  ByteDance: '--forge-vendor-bytedance',
  Tencent: '--forge-vendor-tencent',
  MiniMax: '--forge-vendor-minimax',
  Cohere: '--forge-vendor-cohere',
  Baidu: '--forge-vendor-baidu',
  Others: '--forge-vendor-others',
}

export const FORGE_VENDOR_FALLBACK_TOKENS = [
  '--forge-vendor-openai',
  '--forge-vendor-google',
  '--forge-vendor-anthropic',
  '--forge-vendor-deepseek',
  '--forge-vendor-alibaba',
  '--forge-vendor-xai',
  '--forge-vendor-meta',
  '--forge-vendor-moonshot',
  '--forge-vendor-zhipu',
  '--forge-vendor-mistral',
  '--forge-vendor-bytedance',
  '--forge-vendor-tencent',
  '--forge-vendor-others',
] as const

export function buildForgeChartPalette(theme?: string) {
  return [
    readForgeColor('--forge-model-1', theme),
    readForgeColor('--forge-model-2', theme),
    readForgeColor('--forge-model-3', theme),
    readForgeColor('--forge-model-4', theme),
    readForgeColor('--forge-model-5', theme),
  ]
}

export function buildForgeVendorColorMap(names: string[], theme?: string) {
  let fallbackIndex = 0
  const result: Record<string, string> = {}

  for (const name of names) {
    const token =
      FORGE_VENDOR_COLOR_TOKENS[name] ??
      FORGE_VENDOR_FALLBACK_TOKENS[
        fallbackIndex++ % FORGE_VENDOR_FALLBACK_TOKENS.length
      ]
    result[name] = readForgeColor(token, theme)
  }

  return result
}
