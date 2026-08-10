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
import { useQuery } from '@tanstack/react-query'
import { CheckCircle2, LoaderCircle, Send } from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'

import {
  getAssistantHandoff,
  submitAssistantHandoff,
  type AssistantHandoff,
} from './api'

export function AssistantHandoffTool() {
  const { t } = useTranslation()
  const [message, setMessage] = useState('')
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState<AssistantHandoff | null>(null)
  const handoffQuery = useQuery({
    queryKey: ['assistant-handoff'],
    queryFn: getAssistantHandoff,
    staleTime: 30_000,
    retry: false,
  })
  const current = submitted ?? handoffQuery.data

  const submit = async () => {
    if (submitting || !message.trim()) return
    setSubmitting(true)
    try {
      const result = await submitAssistantHandoff(message.trim())
      setSubmitted(result)
      setConfirmOpen(false)
      toast.success(t('Your message was sent to an administrator'))
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : t('Unable to contact support')
      )
    } finally {
      setSubmitting(false)
    }
  }

  if (current?.status === 'pending') {
    return (
      <Card size='sm' className='border-success/40 bg-success/5'>
        <CardHeader>
          <CardTitle className='flex items-center gap-2'>
            <CheckCircle2 className='text-success size-4' aria-hidden='true' />
            {t('Administrator follow-up requested')}
          </CardTitle>
          <CardDescription>
            {t(
              'Your request is waiting in the administrator queue. You do not need to send it again.'
            )}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Badge variant='outline'>{t('Pending')}</Badge>
        </CardContent>
      </Card>
    )
  }

  return (
    <>
      <Card size='sm'>
        <CardHeader>
          <CardTitle>{t('Send a message to an administrator')}</CardTitle>
          <CardDescription>
            {t(
              'Describe the page, issue, and approximate time. Obvious secrets are removed before storage.'
            )}
          </CardDescription>
        </CardHeader>
        <CardContent className='grid gap-3'>
          {current?.status === 'resolved' ? (
            <div className='bg-muted/50 rounded-lg border p-3 text-xs'>
              <p className='font-medium'>{t('Previous request resolved')}</p>
              {current.admin_note ? (
                <p className='text-muted-foreground mt-1 whitespace-pre-wrap'>
                  {current.admin_note}
                </p>
              ) : null}
            </div>
          ) : null}
          <div className='grid gap-1.5'>
            <Label htmlFor='assistant-handoff-message'>
              {t('Issue description')}
            </Label>
            <Textarea
              id='assistant-handoff-message'
              rows={4}
              maxLength={2000}
              value={message}
              onChange={(event) => setMessage(event.target.value)}
              placeholder={t('What happened, where, and when?')}
            />
          </div>
          <Button
            type='button'
            onClick={() => setConfirmOpen(true)}
            disabled={!message.trim() || handoffQuery.isLoading}
          >
            <Send data-icon='inline-start' aria-hidden='true' />
            {t('Review message')}
          </Button>
        </CardContent>
      </Card>

      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t('Send this message?')}</AlertDialogTitle>
            <AlertDialogDescription>
              {t(
                'The message will be stored for administrators. Do not include passwords, API keys, or session cookies.'
              )}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={submitting}>
              {t('Cancel')}
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={() => void submit()}
              disabled={submitting}
            >
              {submitting ? (
                <LoaderCircle className='animate-spin' aria-hidden='true' />
              ) : null}
              {t('Confirm and send')}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
