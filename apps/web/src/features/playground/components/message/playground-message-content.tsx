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
import { FileTextIcon } from 'lucide-react'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import {
  CodeBlock,
  CodeBlockCopyButton,
} from '@/components/ai-elements/code-block'
import { Loader } from '@/components/ai-elements/loader'
import { MessageContent } from '@/components/ai-elements/message'
import {
  Reasoning,
  ReasoningContent,
  ReasoningTrigger,
} from '@/components/ai-elements/reasoning'
import { Response } from '@/components/ai-elements/response'
import { Shimmer } from '@/components/ai-elements/shimmer'
import {
  Source,
  Sources,
  SourcesContent,
  SourcesTrigger,
} from '@/components/ai-elements/sources'
import { cn } from '@/lib/utils'

import { MESSAGE_STATUS } from '../../constants'
import {
  getMessageAlignmentClass,
  getMessageContentState,
  isErrorMessage,
  type MessageAlignment,
} from '../../lib'
import { getMessageContentStyles } from '../../lib/message/message-styles'
import type { Message } from '../../types'
import { MessageError } from './message-error'
import { MessageMetadata } from './message-metadata'

type PlaygroundMessageContentProps = {
  actions: ReactNode
  alignment: MessageAlignment
  errorActions?: ReactNode
  isSourceVisible?: boolean
  message: Message
  versionContent: string
}

export function PlaygroundMessageContent({
  actions,
  alignment,
  errorActions,
  isSourceVisible = false,
  message,
  versionContent,
}: PlaygroundMessageContentProps) {
  const { t } = useTranslation()
  const {
    displayContent,
    hasReasoning,
    hasSources,
    reasoningContent,
    showLoader,
    showMessageContent,
    sources,
  } = getMessageContentState(message, versionContent)
  const isError = isErrorMessage(message)
  const attachments = message.attachments ?? []
  const hasAttachments = attachments.length > 0
  const isMessageFinal =
    message.status !== MESSAGE_STATUS.LOADING &&
    message.status !== MESSAGE_STATUS.STREAMING
  let renderedMessageContent: ReactNode = null

  if (showMessageContent) {
    renderedMessageContent = isSourceVisible ? (
      <CodeBlock
        code={versionContent}
        className='my-0 group-[.is-assistant]:w-full group-[.is-assistant]:max-w-[78ch]'
        collapsedLines={24}
        defaultCollapsed={false}
        language='markdown'
        maxExpandedLines={48}
        showLineNumbers
        showToolbar
        title={t('Raw response')}
      >
        <CodeBlockCopyButton />
      </CodeBlock>
    ) : (
      <MessageContent variant='flat' className={cn(getMessageContentStyles())}>
        <Response final={isMessageFinal}>{displayContent}</Response>
      </MessageContent>
    )
  }

  return (
    <div
      className={cn(
        'flex w-full min-w-0 flex-col',
        getMessageAlignmentClass(alignment)
      )}
    >
      {hasSources && (
        <Sources>
          <SourcesTrigger count={sources.length} />
          <SourcesContent>
            {sources.map((source) => (
              <Source
                href={source.href}
                key={`${source.href}-${source.title}`}
                title={source.title}
              />
            ))}
          </SourcesContent>
        </Sources>
      )}

      {hasReasoning && (
        <Reasoning
          defaultOpen
          duration={message.reasoning?.duration}
          isStreaming={message.isReasoningStreaming}
        >
          <ReasoningTrigger />
          <ReasoningContent>{reasoningContent}</ReasoningContent>
        </Reasoning>
      )}

      {showLoader && (
        <div className='flex items-center gap-2 py-2'>
          <Loader />
          <Shimmer className='text-sm' duration={1}>
            {t('Responding...')}
          </Shimmer>
        </div>
      )}

      {isError && (
        <>
          <MessageError message={message} className='mb-2' />
          <MessageMetadata alignment={alignment} message={message} />
          {errorActions}
        </>
      )}

      {!isError && (showMessageContent || hasAttachments) && (
        <>
          {hasAttachments && (
            <div
              className={cn(
                'mb-3 flex max-w-2xl flex-wrap gap-2',
                alignment === 'right' && 'self-end justify-end'
              )}
            >
              {attachments.map((attachment) =>
                attachment.kind === 'image' && attachment.url ? (
                  <figure
                    className='border-border/80 bg-muted/30 overflow-hidden rounded-xl border'
                    key={`${attachment.kind}:${attachment.name}:${attachment.url}`}
                  >
                    <img
                      alt={attachment.name}
                      className='max-h-72 max-w-full object-contain sm:max-w-md'
                      loading='lazy'
                      src={attachment.url}
                    />
                    <figcaption className='text-muted-foreground max-w-72 truncate border-t px-2.5 py-1.5 text-xs'>
                      {attachment.name}
                    </figcaption>
                  </figure>
                ) : (
                  <div
                    className='border-border/80 bg-muted/35 text-foreground flex max-w-72 items-center gap-2 rounded-lg border px-3 py-2 text-sm'
                    key={`${attachment.kind}:${attachment.name}:${attachment.mediaType}`}
                  >
                    <FileTextIcon className='text-muted-foreground size-4 shrink-0' />
                    <span className='truncate'>{attachment.name}</span>
                  </div>
                )
              )}
            </div>
          )}
          {renderedMessageContent}
          <MessageMetadata alignment={alignment} message={message} />
          {actions}
        </>
      )}
    </div>
  )
}
