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
import { type ComponentProps, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import {
  PromptInput,
  PromptInputAttachment,
  PromptInputAttachments,
  PromptInputFooter,
  PromptInputTextarea,
  type PromptInputMessage,
  usePromptInputAttachments,
} from '@/components/ai-elements/prompt-input'

import {
  getSubmittableInputText,
  PLAYGROUND_ATTACHMENT_ACCEPT,
  PLAYGROUND_MAX_FILE_BYTES,
  PLAYGROUND_MAX_FILES,
  preparePlaygroundSubmission,
} from '../../lib'
import type {
  ModelOption,
  GroupOption,
  ParameterEnabled,
  PlaygroundConfig,
  PlaygroundSubmission,
} from '../../types'
import { PlaygroundInputControls } from './playground-input-controls'
import { PlaygroundInputTools } from './playground-input-tools'

interface PlaygroundInputProps {
  config: PlaygroundConfig
  onSubmit: (submission: PlaygroundSubmission) => void | Promise<void>
  onStop?: () => void
  disabled?: boolean
  isGenerating?: boolean
  models: ModelOption[]
  modelValue: string
  onModelChange: (value: string) => void
  isModelLoading?: boolean
  groups: GroupOption[]
  groupValue: string
  onGroupChange: (value: string) => void
  hasMessages?: boolean
  onConfigChange: <K extends keyof PlaygroundConfig>(
    key: K,
    value: PlaygroundConfig[K]
  ) => void
  onClearMessages?: () => void
  onParameterEnabledChange: (
    key: keyof ParameterEnabled,
    value: boolean
  ) => void
  parameterEnabled: ParameterEnabled
}

function PlaygroundInputControlsWithAttachments(
  props: ComponentProps<typeof PlaygroundInputControls>
) {
  const attachments = usePromptInputAttachments()
  return (
    <PlaygroundInputControls
      {...props}
      attachmentCount={attachments.files.length}
    />
  )
}

export function PlaygroundInput({
  config,
  onSubmit,
  onStop,
  disabled,
  isGenerating,
  models,
  modelValue,
  onModelChange,
  isModelLoading = false,
  groups,
  groupValue,
  onGroupChange,
  hasMessages = false,
  onConfigChange,
  onClearMessages,
  onParameterEnabledChange,
  parameterEnabled,
}: PlaygroundInputProps) {
  const { t } = useTranslation()
  const [text, setText] = useState('')

  const handleSubmit = async (message: PromptInputMessage) => {
    const submittableText = getSubmittableInputText(message, disabled)

    if (submittableText === null) return
    let submission: PlaygroundSubmission
    try {
      submission = preparePlaygroundSubmission(message)
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : t('Request error occurred')
      )
      throw error
    }
    await onSubmit(submission)
    setText('')
  }

  return (
    <div className='grid shrink-0 gap-4 px-1 md:pb-4'>
      <PromptInput
        accept={PLAYGROUND_ATTACHMENT_ACCEPT}
        className='relative'
        maxFiles={PLAYGROUND_MAX_FILES}
        maxFileSize={PLAYGROUND_MAX_FILE_BYTES}
        multiple
        groupClassName='playground-input-shell'
        onError={(error) => toast.error(t(error.message))}
        onSubmit={handleSubmit}
      >
        <PromptInputTextarea
          autoComplete='off'
          autoCorrect='off'
          autoCapitalize='off'
          spellCheck={false}
          className='min-h-20 px-5 pt-4 pb-3 leading-7 md:min-h-24 md:text-base'
          disabled={disabled}
          onChange={(event) => setText(event.target.value)}
          placeholder={t('Ask anything')}
          value={text}
        />

        <div className='flex flex-wrap gap-2 px-4 pb-3 empty:hidden'>
          <PromptInputAttachments>
            {(attachment) => (
              <PromptInputAttachment data={attachment} key={attachment.id} />
            )}
          </PromptInputAttachments>
        </div>

        <PromptInputFooter className='playground-input-footer px-3 py-2.5'>
          <PlaygroundInputControlsWithAttachments
            disabled={disabled}
            groups={groups}
            groupValue={groupValue}
            isGenerating={isGenerating}
            isModelLoading={isModelLoading}
            models={models}
            modelValue={modelValue}
            onGroupChange={onGroupChange}
            onModelChange={onModelChange}
            onStop={onStop}
            text={text}
            tools={
              <PlaygroundInputTools
                config={config}
                disabled={disabled}
                hasMessages={hasMessages}
                onConfigChange={onConfigChange}
                onClearMessages={onClearMessages}
                onParameterEnabledChange={onParameterEnabledChange}
                parameterEnabled={parameterEnabled}
              />
            }
          />
        </PromptInputFooter>
      </PromptInput>
    </div>
  )
}
