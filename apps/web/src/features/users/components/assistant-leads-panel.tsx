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
import { Check, MessageSquareText, RefreshCw } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import {
  getAssistantIntentSummary,
  listAssistantHandoffs,
  resolveAssistantHandoff,
  type AssistantHandoff,
  type AssistantIntentSummary,
} from '@/features/assistant/api'

const INTENT_LABELS: Record<string, string> = {
  onboarding: 'Onboarding and L1',
  plan_purchase: 'Plans and purchase',
  api_key: 'API keys',
  client_setup: 'Client setup',
  cost: 'Cost calculation',
  bounty: 'Open-source bounties',
  human_support: 'Human support',
  other: 'Other questions',
}

export function AssistantLeadsPanel() {
  const { t, i18n } = useTranslation()
  const [handoffs, setHandoffs] = useState<AssistantHandoff[]>([])
  const [intents, setIntents] = useState<AssistantIntentSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [available, setAvailable] = useState(true)
  const [resolving, setResolving] = useState<number | null>(null)
  const [notes, setNotes] = useState<Record<number, string>>({})

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const [pending, summary] = await Promise.all([
        listAssistantHandoffs('pending'),
        getAssistantIntentSummary(30),
      ])
      setHandoffs(pending)
      setIntents(summary)
      setAvailable(true)
    } catch (error) {
      const status = (error as { response?: { status?: number } }).response
        ?.status
      if (status === 404) {
        setAvailable(false)
      } else {
        toast.error(
          error instanceof Error
            ? error.message
            : t('Unable to load assistant leads')
        )
      }
    } finally {
      setLoading(false)
    }
  }, [t])

  useEffect(() => {
    void load()
  }, [load])

  const totalIntents = useMemo(
    () => intents.reduce((total, item) => total + item.count, 0),
    [intents]
  )
  const dateTimeFormatter = useMemo(
    () =>
      new Intl.DateTimeFormat(i18n.language, {
        dateStyle: 'medium',
        timeStyle: 'short',
      }),
    [i18n.language]
  )

  const resolve = async (handoff: AssistantHandoff) => {
    if (resolving !== null) return
    setResolving(handoff.id)
    try {
      await resolveAssistantHandoff(handoff.id, notes[handoff.id] ?? '')
      setHandoffs((current) => current.filter((item) => item.id !== handoff.id))
      toast.success(t('Support request resolved'))
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : t('Unable to resolve support request')
      )
    } finally {
      setResolving(null)
    }
  }

  if (!available) return null

  const renderHandoffs = () => {
    if (loading && handoffs.length === 0) {
      return (
        <p className='text-muted-foreground mt-5 text-sm'>{t('Loading...')}</p>
      )
    }
    if (handoffs.length === 0) {
      return (
        <p className='text-muted-foreground mt-5 text-sm'>
          {t('No pending human-support requests.')}
        </p>
      )
    }
    return (
      <div className='mt-5 grid gap-3'>
        {handoffs.map((handoff) => (
          <article key={handoff.id} className='bg-background border p-4'>
            <div className='flex flex-wrap items-start justify-between gap-3'>
              <div className='min-w-0'>
                <p className='font-medium'>{handoff.username}</p>
                <p className='text-muted-foreground text-xs'>
                  {handoff.email || t('No email provided')} ·{' '}
                  {dateTimeFormatter.format(
                    new Date(handoff.created_at * 1000)
                  )}
                </p>
              </div>
              <Badge variant='outline'>{t('Pending')}</Badge>
            </div>
            <p className='mt-3 text-sm whitespace-pre-wrap'>
              {handoff.message}
            </p>
            <Textarea
              className='mt-3'
              rows={2}
              maxLength={2000}
              placeholder={t('Optional resolution note for the user')}
              value={notes[handoff.id] ?? ''}
              onChange={(event) =>
                setNotes((current) => ({
                  ...current,
                  [handoff.id]: event.target.value,
                }))
              }
            />
            <div className='mt-3 flex justify-end'>
              <Button
                size='sm'
                onClick={() => void resolve(handoff)}
                disabled={resolving !== null}
              >
                <Check data-icon='inline-start' aria-hidden='true' />
                {t('Mark resolved')}
              </Button>
            </div>
          </article>
        ))}
      </div>
    )
  }

  return (
    <section className='bg-muted/10 border px-5 py-5 sm:px-6'>
      <div className='flex flex-wrap items-start justify-between gap-3'>
        <div>
          <div className='flex items-center gap-2'>
            <MessageSquareText className='size-4' aria-hidden='true' />
            <h2 className='text-sm font-semibold'>{t('AI assistant leads')}</h2>
            <Badge variant='secondary'>{handoffs.length}</Badge>
          </div>
          <p className='text-muted-foreground mt-1 text-sm'>
            {t(
              'Review explicit human-support requests and recent privacy-minimized intent counts.'
            )}
          </p>
        </div>
        <Button
          variant='outline'
          size='sm'
          onClick={() => void load()}
          disabled={loading}
        >
          <RefreshCw
            data-icon='inline-start'
            className={loading ? 'animate-spin' : undefined}
          />
          {t('Refresh')}
        </Button>
      </div>

      <div
        className='mt-4 flex flex-wrap gap-2'
        aria-label={t('Intent summary')}
      >
        <Badge variant='outline'>
          {t('{{count}} questions in 30 days', { count: totalIntents })}
        </Badge>
        {intents.map((item) => (
          <Badge key={item.intent} variant='secondary'>
            {t(INTENT_LABELS[item.intent] ?? 'Other questions')}: {item.count}
          </Badge>
        ))}
      </div>

      {renderHandoffs()}
    </section>
  )
}
