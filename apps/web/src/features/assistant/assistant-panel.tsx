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
import {
  Alert02Icon,
  ArrowRight01Icon,
  CleanIcon,
  ReloadIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { nanoid } from 'nanoid'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'

import {
  Conversation,
  ConversationContent,
  ConversationScrollButton,
} from '@/components/ai-elements/conversation'
import { Loader } from '@/components/ai-elements/loader'
import { Message, MessageContent } from '@/components/ai-elements/message'
import {
  PromptInput,
  PromptInputBody,
  PromptInputFooter,
  PromptInputSubmit,
  PromptInputTextarea,
} from '@/components/ai-elements/prompt-input'
import {
  sideDrawerContentClassName,
  sideDrawerHeaderClassName,
} from '@/components/drawer-layout'
import {
  Alert,
  AlertAction,
  AlertDescription,
  AlertTitle,
} from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'

import {
  getAssistantStatus,
  sendAssistantMessage,
  type AssistantChatMessage,
  type AssistantStatus,
} from './api'
import {
  getAssistantAccountAccessState,
  type AssistantAccountAccessState,
} from './assistant-access'
import { AssistantCostTool } from './assistant-cost-tool'
import type { AssistantPresetId } from './assistant-events'
import { AssistantHandoffTool } from './assistant-handoff-tool'
import { getAssistantPresetForIntent } from './assistant-intent'
import { AssistantKeyTool } from './assistant-key-tool'
import { AssistantPlanTool } from './assistant-plan-tool'
import { AssistantSetupTool } from './assistant-setup-tool'

type AssistantActionPath =
  | '/getting-started'
  | '/pricing'
  | '/keys'
  | '/open-source-bounties'
  | '/support'

type AssistantAction =
  | { kind: 'route'; label: string; to: AssistantActionPath }
  | { kind: 'email'; label: string; href: string }
  | {
      kind: 'tool'
      label: string
      tool: 'key' | 'cost' | 'handoff' | 'plan' | 'setup'
    }

type AssistantPreset = {
  id: AssistantPresetId
  question: string
  answer: string
  action?: AssistantAction
}

type ConversationEntry = {
  id: string
  role: 'user' | 'assistant'
  content: string
  action?: AssistantAction
  error?: boolean
  retry?: {
    message: string
    history: AssistantChatMessage[]
  }
}

function getBaseUrl(): string {
  if (typeof window === 'undefined') return 'https://api.lmm.best/v1'
  return `${window.location.origin}/v1`
}

function PresetAction(props: {
  action: AssistantAction
  onToolOpen: (tool: 'key' | 'cost' | 'handoff' | 'plan' | 'setup') => void
}) {
  const { action } = props
  if (action.kind === 'tool') {
    return (
      <Button variant='outline' onClick={() => props.onToolOpen(action.tool)}>
        {action.label}
        <HugeiconsIcon
          icon={ArrowRight01Icon}
          strokeWidth={2}
          data-icon='inline-end'
          aria-hidden='true'
        />
      </Button>
    )
  }
  if (action.kind === 'email') {
    return (
      <Button variant='outline' render={<a href={action.href} />}>
        {action.label}
        <HugeiconsIcon
          icon={ArrowRight01Icon}
          strokeWidth={2}
          data-icon='inline-end'
          aria-hidden='true'
        />
      </Button>
    )
  }

  return (
    <Button variant='outline' render={<Link to={action.to} />}>
      {action.label}
      <HugeiconsIcon
        icon={ArrowRight01Icon}
        strokeWidth={2}
        data-icon='inline-end'
        aria-hidden='true'
      />
    </Button>
  )
}

function remainingCreditUSD(status: AssistantStatus | undefined): number {
  const credit = status?.credit
  if (!credit || credit.limit_quota <= 0 || credit.remaining_quota <= 0) {
    return 0
  }
  return (
    credit.weekly_credit_usd * (credit.remaining_quota / credit.limit_quota)
  )
}

function AssistantAccountStatusNotice(props: {
  state: Extract<AssistantAccountAccessState, 'loading' | 'error'>
  onRetry: () => void
}) {
  const { t } = useTranslation()
  if (props.state === 'loading') {
    return (
      <Card size='sm' aria-label={t('Loading...')}>
        <CardHeader>
          <CardTitle className='sr-only'>{t('Loading...')}</CardTitle>
          <Skeleton className='h-4 w-44' />
        </CardHeader>
        <CardContent>
          <Skeleton className='h-9 w-full' />
        </CardContent>
      </Card>
    )
  }

  return (
    <Alert variant='destructive'>
      <HugeiconsIcon icon={Alert02Icon} strokeWidth={2} aria-hidden='true' />
      <AlertTitle>{t('Unable to verify account access')}</AlertTitle>
      <AlertDescription>
        {t('Retry before using account-specific assistant tools.')}
      </AlertDescription>
      <AlertAction>
        <Button variant='outline' size='sm' onClick={props.onRetry}>
          {t('Retry')}
        </Button>
      </AlertAction>
    </Alert>
  )
}

export function AssistantPanel(props: {
  open: boolean
  initialPreset?: AssistantPresetId
  onOpenChange: (open: boolean) => void
}) {
  const { t, i18n } = useTranslation()
  const queryClient = useQueryClient()
  const baseUrl = getBaseUrl()
  const presets = useMemo<AssistantPreset[]>(
    () => [
      {
        id: 'onboarding',
        question: t('What can I do while access is under review?'),
        answer: t(
          'You can review pricing, add funds, and explore open-source bounties while an administrator reviews your request. Approval unlocks L1 access; no payment is required for manual approval.'
        ),
        action: {
          kind: 'route',
          label: t('View onboarding status'),
          to: '/getting-started',
        },
      },
      {
        id: 'plan',
        question: t('Which option is the best value?'),
        answer: t(
          'Choose by workload rather than list price. I can compare the live included quota, reset period, and current top-up discounts against your expected usage.'
        ),
        action: {
          kind: 'tool',
          label: t('Compare live plans'),
          tool: 'plan',
        },
      },
      {
        id: 'api-key',
        question: t('What are my Base URL, model ID, and API key?'),
        answer: t(
          'Your Base URL is {{baseUrl}}. Open connection details to copy it, see the current model ID, and create a new API key after explicit confirmation. Existing keys remain private.',
          { baseUrl }
        ),
        action: {
          kind: 'tool',
          label: t('View connection details'),
          tool: 'key',
        },
      },
      {
        id: 'client-setup',
        question: t('How do I set up Claude Code or CC Switch?'),
        answer: t(
          'Windows, Linux, and macOS clients use the same three values: Base URL, model ID, and API key. Open the setup guide for verified install commands and app-specific fields.'
        ),
        action: {
          kind: 'tool',
          label: t('Open client setup guide'),
          tool: 'setup',
        },
      },
      {
        id: 'bounty',
        question: t('How do open-source bounties and tips work?'),
        answer: t(
          'A publisher funds a challenge and reviews submitted work. When a contribution is accepted, the publisher can add a tip before settlement; every financial confirmation shows the exact amount first.'
        ),
        action: {
          kind: 'route',
          label: t('Explore open-source bounties'),
          to: '/open-source-bounties',
        },
      },
      {
        id: 'cost',
        question: t('How is request cost calculated?'),
        answer: t(
          'Estimated cost is input tokens multiplied by the input rate plus output tokens multiplied by the output rate. Cached tokens, images, or tools may have separate rates, so confirm the selected model in Pricing.'
        ),
        action: {
          kind: 'tool',
          label: t('Calculate with live pricing'),
          tool: 'cost',
        },
      },
      {
        id: 'human',
        question: t('I need human support'),
        answer: t(
          'Describe the account, billing, or technical issue and include the page and approximate time. Never include an API key or password in the message.'
        ),
        action: {
          kind: 'tool',
          label: t('Send to an administrator'),
          tool: 'handoff',
        },
      },
    ],
    [baseUrl, t]
  )

  const [entries, setEntries] = useState<ConversationEntry[]>(() => {
    const preset = presets.find((item) => item.id === props.initialPreset)
    if (!preset) return []
    return [
      { id: nanoid(), role: 'user', content: preset.question },
      {
        id: nanoid(),
        role: 'assistant',
        content: preset.answer,
        action: preset.action,
      },
    ]
  })
  const [sending, setSending] = useState(false)
  const [activeTool, setActiveTool] = useState<
    'key' | 'cost' | 'handoff' | 'plan' | 'setup' | null
  >(null)
  const statusQuery = useQuery({
    queryKey: ['assistant-status'],
    queryFn: getAssistantStatus,
    enabled: props.open,
    staleTime: 30_000,
    retry: false,
  })
  const accountAccessState = getAssistantAccountAccessState(
    statusQuery.data,
    statusQuery.isError
  )
  const accountAccessConfirmed =
    accountAccessState === 'granted' || accountAccessState === 'restricted'
  const developerAccessGranted = accountAccessState === 'granted'
  const accountToolActive = activeTool !== null && activeTool !== 'handoff'

  const creditLabel = useMemo(
    () =>
      new Intl.NumberFormat(i18n.language, {
        style: 'currency',
        currency: 'USD',
        maximumFractionDigits: 2,
      }).format(remainingCreditUSD(statusQuery.data)),
    [i18n.language, statusQuery.data]
  )

  const appendPreset = (preset: AssistantPreset) => {
    setActiveTool(null)
    setEntries((current) => [
      ...current,
      {
        id: nanoid(),
        role: 'user',
        content: preset.question,
      },
      {
        id: nanoid(),
        role: 'assistant',
        content: preset.answer,
        action: preset.action,
      },
    ])
  }

  const handleOpenChange = (open: boolean) => {
    if (!open) setActiveTool(null)
    props.onOpenChange(open)
  }

  const requestAssistantReply = async (
    message: string,
    history: AssistantChatMessage[]
  ) => {
    setSending(true)
    try {
      const reply = await sendAssistantMessage(message, history)
      const suggestedPresetId = getAssistantPresetForIntent(reply.intent)
      const suggestedAction = suggestedPresetId
        ? presets.find((preset) => preset.id === suggestedPresetId)?.action
        : undefined
      setEntries((current) => [
        ...current,
        {
          id: nanoid(),
          role: 'assistant',
          content: reply.content,
          action: suggestedAction,
        },
      ])
      await queryClient.invalidateQueries({ queryKey: ['assistant-status'] })
    } catch {
      setEntries((current) => [
        ...current,
        {
          id: nanoid(),
          role: 'assistant',
          content: t(
            'The AI assistant could not answer right now. Try again or contact support.'
          ),
          error: true,
          retry: { message, history },
          action: {
            kind: 'route',
            label: t('Contact support'),
            to: '/support',
          },
        },
      ])
    } finally {
      setSending(false)
    }
  }

  const submitMessage = async ({ text }: { text?: string }) => {
    const message = text?.trim()
    if (!message || sending) return
    const history: AssistantChatMessage[] = entries
      .filter((entry) => !entry.error)
      .map((entry) => ({ role: entry.role, content: entry.content }))
    setEntries((current) => [
      ...current,
      { id: nanoid(), role: 'user', content: message },
    ])
    await requestAssistantReply(message, history)
  }

  const retryMessage = async (entry: ConversationEntry) => {
    if (!entry.retry || sending) return
    setEntries((current) => current.filter((item) => item.id !== entry.id))
    await requestAssistantReply(entry.retry.message, entry.retry.history)
  }

  return (
    <Sheet open={props.open} onOpenChange={handleOpenChange}>
      <SheetContent
        className={sideDrawerContentClassName('max-w-none sm:!max-w-[480px]')}
      >
        <SheetHeader className={sideDrawerHeaderClassName('pr-12')}>
          <div className='flex flex-wrap items-center gap-2'>
            <SheetTitle>{t('AI assistant')}</SheetTitle>
            <Badge variant='secondary'>{t('Service guide')}</Badge>
            {statusQuery.data?.model ? (
              <Badge variant='outline'>{statusQuery.data.model}</Badge>
            ) : null}
          </div>
          <SheetDescription>
            {t('Guidance for plans, setup, API keys, costs, and support.')}
          </SheetDescription>
        </SheetHeader>

        <Conversation className='bg-muted/20'>
          <ConversationContent className='flex min-h-full flex-col gap-5 px-4 py-5 sm:px-6'>
            {entries.length === 0 ? (
              <div className='flex flex-1 flex-col gap-5'>
                <div>
                  <p className='text-base font-medium'>
                    {t('How can I help?')}
                  </p>
                  <p className='text-muted-foreground mt-1 text-sm leading-6'>
                    {t(
                      'Choose a common question or ask anything about using LMM.'
                    )}
                  </p>
                </div>
                <div className='grid gap-2'>
                  {presets.map((preset) => (
                    <Button
                      key={preset.id}
                      type='button'
                      variant='outline'
                      className='h-auto min-h-11 justify-between gap-3 px-3 py-2.5 text-left whitespace-normal'
                      onClick={() => appendPreset(preset)}
                    >
                      <span>{preset.question}</span>
                      <HugeiconsIcon
                        icon={ArrowRight01Icon}
                        strokeWidth={2}
                        className='shrink-0'
                        aria-hidden='true'
                      />
                    </Button>
                  ))}
                </div>
              </div>
            ) : (
              <>
                {entries.map((entry) => (
                  <Message from={entry.role} key={entry.id}>
                    <MessageContent
                      variant='flat'
                      className={
                        entry.error
                          ? 'text-destructive gap-3 text-sm leading-6'
                          : 'gap-3 text-sm leading-6'
                      }
                    >
                      <p className='whitespace-pre-wrap'>{entry.content}</p>
                      {entry.retry || entry.action ? (
                        <div className='flex flex-wrap gap-2'>
                          {entry.retry ? (
                            <Button
                              type='button'
                              variant='outline'
                              onClick={() => void retryMessage(entry)}
                              disabled={sending}
                            >
                              <HugeiconsIcon
                                icon={ReloadIcon}
                                strokeWidth={2}
                                data-icon='inline-start'
                                aria-hidden='true'
                              />
                              {t('Retry')}
                            </Button>
                          ) : null}
                          {entry.action ? (
                            <PresetAction
                              action={entry.action}
                              onToolOpen={setActiveTool}
                            />
                          ) : null}
                        </div>
                      ) : null}
                    </MessageContent>
                  </Message>
                ))}
                {sending ? (
                  <Message from='assistant'>
                    <MessageContent
                      variant='flat'
                      className='text-muted-foreground flex-row items-center gap-2'
                      aria-live='polite'
                    >
                      <Loader size={14} />
                      <span>{t('Assistant is thinking...')}</span>
                    </MessageContent>
                  </Message>
                ) : null}
                {accountToolActive && !accountAccessConfirmed ? (
                  <AssistantAccountStatusNotice
                    state={accountAccessState === 'error' ? 'error' : 'loading'}
                    onRetry={() => void statusQuery.refetch()}
                  />
                ) : null}
                {activeTool === 'key' && accountAccessConfirmed ? (
                  <AssistantKeyTool
                    baseUrl={baseUrl}
                    defaultModel={statusQuery.data?.model ?? ''}
                    developerAccessGranted={developerAccessGranted}
                  />
                ) : null}
                {activeTool === 'cost' && accountAccessConfirmed ? (
                  <AssistantCostTool
                    defaultModel={statusQuery.data?.model ?? ''}
                    developerAccessGranted={developerAccessGranted}
                  />
                ) : null}
                {activeTool === 'handoff' ? <AssistantHandoffTool /> : null}
                {activeTool === 'plan' && accountAccessConfirmed ? (
                  <AssistantPlanTool
                    developerAccessGranted={developerAccessGranted}
                  />
                ) : null}
                {activeTool === 'setup' && accountAccessConfirmed ? (
                  <AssistantSetupTool
                    rootUrl={baseUrl.replace(/\/v1$/, '')}
                    openAIBaseUrl={baseUrl}
                    defaultModel={statusQuery.data?.model ?? ''}
                    developerAccessGranted={developerAccessGranted}
                    onCreateKey={() => setActiveTool('key')}
                  />
                ) : null}
                <div className='grid gap-3 pt-1'>
                  <Separator />
                  <Button
                    type='button'
                    variant='ghost'
                    size='sm'
                    onClick={() => {
                      setEntries([])
                      setActiveTool(null)
                    }}
                    disabled={sending}
                  >
                    <HugeiconsIcon
                      icon={CleanIcon}
                      strokeWidth={2}
                      data-icon='inline-start'
                      aria-hidden='true'
                    />
                    {t('Clear conversation')}
                  </Button>
                </div>
              </>
            )}
          </ConversationContent>
          <ConversationScrollButton />
        </Conversation>

        <div className='bg-background'>
          <Separator className='bg-border/70' />
          <div className='px-3 py-3 sm:px-4'>
            <PromptInput
              onSubmit={submitMessage}
              groupClassName='rounded-xl'
              aria-label={t('Ask AI assistant')}
            >
              <PromptInputBody>
                <PromptInputTextarea
                  placeholder={t('Ask about plans, setup, keys, or costs...')}
                  maxLength={4000}
                  disabled={sending}
                  className='min-h-14'
                />
              </PromptInputBody>
              <PromptInputFooter>
                <span className='text-muted-foreground truncate text-xs'>
                  {statusQuery.data
                    ? t('Weekly included credit remaining: {{amount}}', {
                        amount: creditLabel,
                      })
                    : t('Weekly included AI credit applies first.')}
                </span>
                <PromptInputSubmit
                  status={sending ? 'submitted' : 'ready'}
                  disabled={sending}
                />
              </PromptInputFooter>
            </PromptInput>
            <p className='text-muted-foreground mt-2 px-1 text-[11px] leading-4'>
              {t(
                'AI answers may be inaccurate. Never send passwords or API keys.'
              )}
            </p>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  )
}
