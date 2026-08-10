/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
*/
import { Check, RefreshCw, X } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'

import {
  listDeveloperAccessRequests,
  reviewDeveloperAccessRequest,
  type DeveloperAccessRequestAdmin,
} from '../api'

export function DeveloperAccessRequestsPanel() {
  const { t } = useTranslation()
  const [requests, setRequests] = useState<DeveloperAccessRequestAdmin[]>([])
  const [loading, setLoading] = useState(true)
  const [available, setAvailable] = useState(true)
  const [reviewing, setReviewing] = useState<number | null>(null)
  const [notes, setNotes] = useState<Record<number, string>>({})

  const loadRequests = useCallback(async () => {
    setLoading(true)
    try {
      const response = await listDeveloperAccessRequests('pending')
      if (!response.success) {
        throw new Error(response.message || t('Unable to load unlock requests'))
      }
      setRequests(response.data ?? [])
      setAvailable(true)
    } catch (error) {
      // A mixed-version deployment may not have the optional admin route yet;
      // hide the panel instead of showing a noisy global error in that case.
      const status = (error as { response?: { status?: number } }).response
        ?.status
      if (status === 404) {
        setAvailable(false)
      } else {
        toast.error(
          error instanceof Error
            ? error.message
            : t('Unable to load unlock requests')
        )
      }
    } finally {
      setLoading(false)
    }
  }, [t])

  useEffect(() => {
    void loadRequests()
  }, [loadRequests])

  const review = async (
    request: DeveloperAccessRequestAdmin,
    approve: boolean
  ) => {
    if (reviewing !== null) return
    setReviewing(request.id)
    try {
      const response = await reviewDeveloperAccessRequest(
        request.id,
        approve ? 'approve' : 'reject',
        notes[request.id] ?? ''
      )
      if (!response.success) {
        throw new Error(
          response.message || t('Unable to review unlock request')
        )
      }
      toast.success(
        approve ? t('Access request approved') : t('Access request rejected')
      )
      setRequests((current) => current.filter((item) => item.id !== request.id))
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : t('Unable to review unlock request')
      )
    } finally {
      setReviewing(null)
    }
  }

  if (!available) return null

  return (
    <section className='bg-muted/10 border px-5 py-5 sm:px-6'>
      <div className='flex flex-wrap items-center justify-between gap-3'>
        <div>
          <div className='flex items-center gap-2'>
            <h2 className='text-sm font-semibold'>{t('Unlock requests')}</h2>
            <Badge variant='secondary'>{requests.length}</Badge>
          </div>
          <p className='text-muted-foreground mt-1 text-sm'>
            {t(
              'Review requests from L0 users who need L1 access without a payment.'
            )}
          </p>
        </div>
        <Button
          variant='outline'
          size='sm'
          onClick={() => void loadRequests()}
          disabled={loading}
        >
          <RefreshCw
            data-icon='inline-start'
            className={loading ? 'animate-spin' : undefined}
          />
          {t('Refresh')}
        </Button>
      </div>

      {loading && requests.length === 0 ? (
        <p className='text-muted-foreground mt-5 text-sm'>{t('Loading...')}</p>
      ) : requests.length === 0 ? (
        <p className='text-muted-foreground mt-5 text-sm'>
          {t('No pending unlock requests.')}
        </p>
      ) : (
        <div className='mt-5 grid gap-3'>
          {requests.map((request) => (
            <article key={request.id} className='bg-background border p-4'>
              <div className='flex flex-wrap items-start justify-between gap-3'>
                <div className='min-w-0'>
                  <p className='font-medium'>{request.username}</p>
                  <p className='text-muted-foreground text-xs'>
                    {request.email || t('No email provided')} · #{request.id}
                  </p>
                </div>
                <Badge variant='outline'>{t('Pending review')}</Badge>
              </div>
              <p className='text-muted-foreground mt-3 text-sm whitespace-pre-wrap'>
                {request.reason || t('No reason provided.')}
              </p>
              <Textarea
                className='mt-3'
                rows={2}
                maxLength={2000}
                placeholder={t('Optional note for the user')}
                value={notes[request.id] ?? ''}
                onChange={(event) =>
                  setNotes((current) => ({
                    ...current,
                    [request.id]: event.target.value,
                  }))
                }
              />
              <div className='mt-3 flex flex-wrap justify-end gap-2'>
                <Button
                  size='sm'
                  variant='destructive'
                  onClick={() => void review(request, false)}
                  disabled={reviewing !== null}
                >
                  <X data-icon='inline-start' />
                  {t('Reject')}
                </Button>
                <Button
                  size='sm'
                  onClick={() => void review(request, true)}
                  disabled={reviewing !== null}
                >
                  <Check data-icon='inline-start' />
                  {t('Approve and unlock L1')}
                </Button>
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  )
}
