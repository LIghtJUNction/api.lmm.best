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
import { Link } from '@tanstack/react-router'
import { ArrowRight, RotateCcw } from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import {
  Conversation,
  ConversationContent,
} from '@/components/ai-elements/conversation'
import { Message, MessageContent } from '@/components/ai-elements/message'
import {
  sideDrawerContentClassName,
  sideDrawerHeaderClassName,
} from '@/components/drawer-layout'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'

import type { AssistantPresetId } from './assistant-events'

type AssistantActionPath =
  | '/getting-started'
  | '/pricing'
  | '/keys'
  | '/open-source-bounties'

type AssistantPreset = {
  id: AssistantPresetId
  question: string
  answer: string
  action?:
    | { kind: 'route'; label: string; to: AssistantActionPath }
    | { kind: 'email'; label: string; href: string }
}

function getBaseUrl(): string {
  if (typeof window === 'undefined') return 'https://api.lmm.best/v1'
  return `${window.location.origin}/v1`
}

function PresetAction({
  action,
}: {
  action: NonNullable<AssistantPreset['action']>
}) {
  if (action.kind === 'email') {
    return (
      <Button variant='outline' render={<a href={action.href} />}>
        {action.label}
        <ArrowRight data-icon='inline-end' aria-hidden='true' />
      </Button>
    )
  }

  return (
    <Button variant='outline' render={<Link to={action.to} />}>
      {action.label}
      <ArrowRight data-icon='inline-end' aria-hidden='true' />
    </Button>
  )
}

export function AssistantPanel(props: {
  open: boolean
  initialPreset?: AssistantPresetId
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation()
  const [selectedId, setSelectedId] = useState<AssistantPresetId | undefined>(
    props.initialPreset
  )
  const baseUrl = getBaseUrl()
  const presets: AssistantPreset[] = [
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
        'Choose by workload rather than list price. Compare input, output, and cached-token prices against your expected usage; available discounts are shown before purchase.'
      ),
      action: { kind: 'route', label: t('Compare pricing'), to: '/pricing' },
    },
    {
      id: 'api-key',
      question: t('How do I create and use an API key?'),
      answer: t(
        'Use {{baseUrl}} as the Base URL. Create a key on the API Keys page, then copy an exact model ID from Pricing. Keep the key private because it may only be displayed once.',
        { baseUrl }
      ),
      action: { kind: 'route', label: t('Create API Key'), to: '/keys' },
    },
    {
      id: 'client-setup',
      question: t('How do I set up Claude Code or CC Switch?'),
      answer: t(
        'Windows, Linux, and macOS clients use the same three values: Base URL, model ID, and API key. In CC Switch, create an OpenAI-compatible provider and enter those values; use the client guide for app-specific fields.'
      ),
      action: { kind: 'route', label: t('Get API credentials'), to: '/keys' },
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
        kind: 'route',
        label: t('Open cost reference'),
        to: '/pricing',
      },
    },
    {
      id: 'human',
      question: t('I need human support'),
      answer: t(
        'Describe the account, billing, or technical issue and include the page and approximate time. Never include an API key or password in the message.'
      ),
      action: {
        kind: 'email',
        label: t('Contact support'),
        href: 'mailto:support@lmm.best?subject=LMM%20support',
      },
    },
  ]
  const selected = presets.find((preset) => preset.id === selectedId)

  return (
    <Sheet open={props.open} onOpenChange={props.onOpenChange}>
      <SheetContent
        className={sideDrawerContentClassName('max-w-none sm:!max-w-[460px]')}
      >
        <SheetHeader className={sideDrawerHeaderClassName('pr-12')}>
          <div className='flex items-center gap-2'>
            <SheetTitle>{t('AI assistant')}</SheetTitle>
            <Badge variant='secondary'>{t('Service guide')}</Badge>
          </div>
          <SheetDescription>
            {t('Guidance for plans, setup, API keys, costs, and support.')}
          </SheetDescription>
        </SheetHeader>

        <Conversation className='bg-muted/20'>
          <ConversationContent className='flex min-h-full flex-col gap-5 px-4 py-5 sm:px-6'>
            {selected ? (
              <>
                <Message from='user'>
                  <MessageContent variant='flat'>
                    {selected.question}
                  </MessageContent>
                </Message>
                <Message from='assistant'>
                  <MessageContent
                    variant='flat'
                    className='gap-3 text-sm leading-6'
                  >
                    <p>{selected.answer}</p>
                    {selected.action ? (
                      <div>
                        <PresetAction action={selected.action} />
                      </div>
                    ) : null}
                  </MessageContent>
                </Message>
                <div className='border-t pt-5'>
                  <Button
                    type='button'
                    variant='ghost'
                    onClick={() => setSelectedId(undefined)}
                  >
                    <RotateCcw data-icon='inline-start' aria-hidden='true' />
                    {t('Ask another question')}
                  </Button>
                </div>
              </>
            ) : (
              <div className='flex flex-1 flex-col gap-5'>
                <div>
                  <p className='text-base font-medium'>
                    {t('How can I help?')}
                  </p>
                  <p className='text-muted-foreground mt-1 text-sm leading-6'>
                    {t('Choose a common question to get a direct answer.')}
                  </p>
                </div>
                <div className='grid gap-2'>
                  {presets.map((preset) => (
                    <Button
                      key={preset.id}
                      type='button'
                      variant='outline'
                      className='h-auto min-h-11 justify-between gap-3 px-3 py-2.5 text-left whitespace-normal'
                      onClick={() => setSelectedId(preset.id)}
                    >
                      <span>{preset.question}</span>
                      <ArrowRight className='shrink-0' aria-hidden='true' />
                    </Button>
                  ))}
                </div>
              </div>
            )}
          </ConversationContent>
        </Conversation>
      </SheetContent>
    </Sheet>
  )
}
