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
import { AiChat02Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { lazy, Suspense, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { useStatus } from '@/hooks/use-status'

import {
  consumeQueuedAssistantPreset,
  subscribeToAssistantOpen,
  type AssistantPresetId,
} from './assistant-events'

const loadAssistantPanel = () => import('./assistant-panel')
const AssistantPanel = lazy(() =>
  loadAssistantPanel().then((module) => ({
    default: module.AssistantPanel,
  }))
)

export function AssistantLauncher() {
  const { t } = useTranslation()
  const { status } = useStatus()
  const [open, setOpen] = useState(false)
  const [hasOpened, setHasOpened] = useState(false)
  const [initialPreset, setInitialPreset] = useState<AssistantPresetId>()

  const showAssistant = (preset?: AssistantPresetId) => {
    setInitialPreset(preset)
    setHasOpened(true)
    setOpen(true)
  }

  useEffect(() => {
    const queuedPreset = consumeQueuedAssistantPreset()
    if (queuedPreset) showAssistant(queuedPreset)
    return subscribeToAssistantOpen(showAssistant)
  }, [])

  const preload = () => {
    void loadAssistantPanel()
  }

  if (status?.assistant?.enabled === false) return null

  return (
    <>
      <Button
        type='button'
        size='icon-lg'
        className='fixed right-4 bottom-4 z-40 size-12 rounded-full shadow-lg sm:right-6 sm:bottom-6'
        aria-label={t('Open AI assistant')}
        title={t('Open AI assistant')}
        onClick={() => showAssistant()}
        onMouseEnter={preload}
        onFocus={preload}
      >
        <HugeiconsIcon icon={AiChat02Icon} strokeWidth={2} />
      </Button>

      {hasOpened ? (
        <Suspense fallback={null}>
          <AssistantPanel
            open={open}
            initialPreset={initialPreset}
            onOpenChange={setOpen}
          />
        </Suspense>
      ) : null}
    </>
  )
}
