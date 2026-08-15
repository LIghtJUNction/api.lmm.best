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
const PROMPT_KEY_PREFIX = 'lmm:onboarding-assistant:v2'
const claimedPrompts = new Set<string>()

type PromptStorage = Pick<Storage, 'getItem' | 'setItem'>

function getSessionStorage(): PromptStorage | undefined {
  if (typeof window === 'undefined') return undefined
  try {
    return window.sessionStorage
  } catch {
    return undefined
  }
}

/**
 * Claims the one-time assistant prompt for a specific review request.
 * Session storage prevents repeated prompts after reloads, while the module
 * cache keeps the same behavior when browser storage is unavailable.
 */
export function claimOnboardingAssistantPrompt(
  userId: number,
  requestId = 0,
  storage: PromptStorage | undefined = getSessionStorage()
): boolean {
  if (!Number.isInteger(userId) || userId <= 0) return false
  if (!Number.isInteger(requestId) || requestId < 0) return false

  const promptId = requestId > 0 ? `review:${requestId}` : 'start'
  const key = `${PROMPT_KEY_PREFIX}:${userId}:${promptId}`
  if (claimedPrompts.has(key)) return false

  try {
    if (storage?.getItem(key) === 'shown') {
      claimedPrompts.add(key)
      return false
    }
  } catch {
    // The in-memory claim remains available in restricted storage contexts.
  }

  claimedPrompts.add(key)
  try {
    storage?.setItem(key, 'shown')
  } catch {
    // Opening once per app lifetime is still preferable to blocking guidance.
  }
  return true
}

export function claimPendingReviewAssistantPrompt(
  userId: number,
  requestId: number,
  storage: PromptStorage | undefined = getSessionStorage()
): boolean {
  if (!Number.isInteger(requestId) || requestId <= 0) return false
  return claimOnboardingAssistantPrompt(userId, requestId, storage)
}
