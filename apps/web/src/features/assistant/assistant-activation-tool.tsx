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
/*
Copyright (C) 2026 LIghtJUNction
*/
import {
  ArrowRight01Icon,
  CheckmarkCircle02Icon,
  ReloadIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Textarea } from '@/components/ui/textarea'
import {
  getDeveloperAccessRequest,
  submitDeveloperAccessRequest,
  type DeveloperAccessRequest,
} from '@/features/onboarding/api'

export function AssistantActivationTool(props: {
  onContinueSetup?: () => void
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [requestOverride, setRequestOverride] =
    useState<DeveloperAccessRequest | null>(null)
  const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(false)
  const trimmedReason = reason.trim()
  const reasonLength = [...trimmedReason].length
  const reasonIsValid = reasonLength >= 5
  const reasonHasError = reason.length > 0 && !reasonIsValid
  let reasonHelpText = t('{{count}}/5 characters', { count: reasonLength })
  if (reason.length === 0) {
    reasonHelpText = t('Application reason is required.')
  } else if (!reasonIsValid) {
    reasonHelpText = t('Application reason must contain at least 5 characters.')
  }

  const requestQuery = useQuery({
    queryKey: ['assistant-developer-access-request'],
    queryFn: getDeveloperAccessRequest,
    staleTime: 0,
    retry: false,
  })
  const request = requestOverride ?? requestQuery.data ?? null

  const refreshStatus = async () => {
    const result = await requestQuery.refetch()
    if (result.error) {
      toast.error(t('Refresh failed'))
      return
    }
    setRequestOverride(result.data ?? null)
    if (result.data?.status === 'approved') {
      await queryClient.invalidateQueries({ queryKey: ['assistant-status'] })
    }
  }

  const submit = async () => {
    if (loading || request?.status === 'pending' || !reasonIsValid) return
    setLoading(true)
    try {
      setRequestOverride(await submitDeveloperAccessRequest(trimmedReason))
      setReason('')
      toast.success(t('Unlock request submitted'))
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : t('Unable to submit unlock request')
      )
    } finally {
      setLoading(false)
    }
  }

  if (request?.status === 'approved') {
    return (
      <Card size='sm' className='border-success/40 bg-success/5'>
        <CardHeader>
          <CardTitle className='flex items-center gap-2'>
            <HugeiconsIcon
              icon={CheckmarkCircle02Icon}
              className='text-success size-4'
              strokeWidth={2}
              aria-hidden='true'
            />
            {t('L1 access approved')}
          </CardTitle>
          <CardDescription>
            {t(
              'Your developer access is active. Continue setup to create a key and connect your client.'
            )}
          </CardDescription>
        </CardHeader>
        {props.onContinueSetup ? (
          <CardContent>
            <Button type='button' onClick={props.onContinueSetup}>
              {t('Continue setup')}
              <HugeiconsIcon
                icon={ArrowRight01Icon}
                strokeWidth={2}
                data-icon='inline-end'
                aria-hidden='true'
              />
            </Button>
          </CardContent>
        ) : null}
      </Card>
    )
  }

  return (
    <Card size='sm' className='border-primary/30 bg-primary/5'>
      <CardHeader>
        <CardTitle>{t('Unlock L1 access')}</CardTitle>
        <CardDescription>
          {t(
            'Tell the administrator what you want to use the service for. The request is free and must contain at least 5 characters.'
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className='grid gap-3'>
        {request?.status === 'pending' ? (
          <div className='grid gap-3'>
            <p className='text-muted-foreground text-xs leading-5'>
              {t(
                'Your free unlock request is waiting for administrator review.'
              )}
            </p>
            <Button
              type='button'
              variant='outline'
              size='sm'
              onClick={() => void refreshStatus()}
              disabled={requestQuery.isFetching}
            >
              <HugeiconsIcon
                icon={ReloadIcon}
                className={requestQuery.isFetching ? 'animate-spin' : undefined}
                strokeWidth={2}
                data-icon='inline-start'
                aria-hidden='true'
              />
              {requestQuery.isFetching ? t('Refreshing...') : t('Refresh')}
            </Button>
          </div>
        ) : (
          <>
            <Textarea
              id='assistant-activation-reason'
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              rows={4}
              required
              minLength={5}
              maxLength={2000}
              aria-invalid={reasonHasError}
              aria-describedby='assistant-activation-reason-help'
              placeholder={t(
                'Write a short explanation of what you want to build or why you need L1 access.'
              )}
            />
            <p
              id='assistant-activation-reason-help'
              className={
                reasonHasError
                  ? 'text-destructive text-xs'
                  : 'text-muted-foreground text-xs'
              }
            >
              {reasonHelpText}
            </p>
            <Button
              type='button'
              onClick={() => void submit()}
              disabled={loading || !reasonIsValid}
            >
              {loading ? t('Submitting...') : t('Send free review request')}
            </Button>
          </>
        )}
      </CardContent>
    </Card>
  )
}
