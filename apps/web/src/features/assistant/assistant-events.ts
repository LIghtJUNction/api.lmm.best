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
export type AssistantPresetId =
  | 'onboarding'
  | 'service'
  | 'plan'
  | 'api-key'
  | 'client-setup'
  | 'bounty'
  | 'cost'
  | 'usage'
  | 'models'
  | 'invitation'
  | 'human'

const ASSISTANT_OPEN_EVENT = 'lmm:assistant:open'
const ASSISTANT_QUEUE_KEY = 'lmm_assistant_queued_preset'
const ASSISTANT_MESSAGE_QUEUE_KEY = 'lmm_assistant_queued_message'

let memoryQueue: AssistantPresetId | null = null
let memoryMessage: string | null = null

function isAssistantPresetId(value: string): value is AssistantPresetId {
  return [
    'onboarding',
    'service',
    'plan',
    'api-key',
    'client-setup',
    'bounty',
    'cost',
    'usage',
    'models',
    'invitation',
    'human',
  ].includes(value)
}

export function requestAssistantOpen(
  preset?: AssistantPresetId,
  message?: string
): void {
  memoryQueue = preset ?? null
  memoryMessage = message?.trim() || null

  if (typeof window === 'undefined') return

  try {
    if (preset) window.sessionStorage.setItem(ASSISTANT_QUEUE_KEY, preset)
    else window.sessionStorage.removeItem(ASSISTANT_QUEUE_KEY)
    if (memoryMessage) {
      window.sessionStorage.setItem(ASSISTANT_MESSAGE_QUEUE_KEY, memoryMessage)
    } else {
      window.sessionStorage.removeItem(ASSISTANT_MESSAGE_QUEUE_KEY)
    }
  } catch {
    // The in-memory queue still covers restricted storage environments.
  }

  window.dispatchEvent(
    new CustomEvent<AssistantPresetId | undefined>(ASSISTANT_OPEN_EVENT, {
      detail: preset,
    })
  )
}

export function consumeQueuedAssistantPreset(): AssistantPresetId | undefined {
  let preset = memoryQueue ?? undefined
  memoryQueue = null

  if (typeof window === 'undefined') return preset

  try {
    const stored = window.sessionStorage.getItem(ASSISTANT_QUEUE_KEY)
    window.sessionStorage.removeItem(ASSISTANT_QUEUE_KEY)
    if (stored && isAssistantPresetId(stored)) preset = stored
  } catch {
    // Fall back to the in-memory value when storage is unavailable.
  }

  return preset
}

export function consumeQueuedAssistantMessage(): string | undefined {
  const message = memoryMessage ?? undefined
  memoryMessage = null

  if (typeof window === 'undefined') return message

  try {
    const stored = window.sessionStorage.getItem(ASSISTANT_MESSAGE_QUEUE_KEY)
    window.sessionStorage.removeItem(ASSISTANT_MESSAGE_QUEUE_KEY)
    return stored?.trim() || message
  } catch {
    return message
  }
}

export function subscribeToAssistantOpen(
  listener: (preset?: AssistantPresetId) => void
): () => void {
  if (typeof window === 'undefined') return () => undefined

  const handleOpen = (event: Event) => {
    const preset = (event as CustomEvent<AssistantPresetId | undefined>).detail
    consumeQueuedAssistantPreset()
    listener(preset)
  }

  window.addEventListener(ASSISTANT_OPEN_EVENT, handleOpen)
  return () => window.removeEventListener(ASSISTANT_OPEN_EVENT, handleOpen)
}
