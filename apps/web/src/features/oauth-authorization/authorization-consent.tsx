/*
Copyright (C) 2026 LIghtJUNction

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/
import { useMutation, useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import {
  AlertTriangle,
  Check,
  Download,
  KeyRound,
  LockKeyhole,
  MonitorSmartphone,
} from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { ErrorState } from '@/components/error-state'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuthStore } from '@/stores/auth-store'

import {
  decideOAuthAuthorization,
  getOAuthAuthorizationPreview,
} from './api'
import { OAuthDecisionActions } from './oauth-decision-actions'
import { OAuthPageShell } from './oauth-page-shell'
import {
  getLoopbackCallbackLabel,
  isSafeOAuthDecisionRedirect,
} from './oauth-utils'
import type { OAuthScope } from './types'

function AuthorizationLoading() {
  const { t } = useTranslation()
  return (
    <Card aria-busy='true' aria-label={t('Loading authorization request')}>
      <CardHeader>
        <Skeleton className='h-5 w-40' />
        <Skeleton className='h-4 w-64 max-w-full' />
      </CardHeader>
      <CardContent className='space-y-4'>
        <Skeleton className='h-16 w-full' />
        <Skeleton className='h-14 w-full' />
        <Skeleton className='h-14 w-full' />
      </CardContent>
      <CardFooter className='gap-2'>
        <Skeleton className='h-9 flex-1' />
        <Skeleton className='h-9 flex-1' />
      </CardFooter>
    </Card>
  )
}

function getScopeCopy(scope: string, t: ReturnType<typeof useTranslation>['t']) {
  switch (scope as OAuthScope) {
    case 'api_keys:list':
      return {
        title: t('View your API Key list'),
        description: t('Read Key names, status, and identifiers.'),
        Icon: KeyRound,
      }
    case 'api_keys:create':
      return {
        title: t('Create an API Key'),
        description: t('Create a dedicated Key for this local setup.'),
        Icon: KeyRound,
      }
    case 'api_keys:reveal':
      return {
        title: t('Reveal the selected API Key once'),
        description: t('Retrieve one Key only after you choose it.'),
        Icon: KeyRound,
      }
    case 'cc_switch:import':
      return {
        title: t('Import into CC Switch'),
        description: t('Hand the selected Key to CC Switch on this device.'),
        Icon: Download,
      }
    default:
      return {
        title: scope,
        description: t('A permission requested by this client.'),
        Icon: Check,
      }
  }
}

function getErrorDescription(
  error: unknown,
  t: ReturnType<typeof useTranslation>['t']
) {
  if (typeof error === 'object' && error != null && 'response' in error) {
    const status = (error as { response?: { status?: number } }).response?.status
    if (status === 400 || status === 404) {
      return t(
        'This authorization request is invalid or has expired. Start login again from the CLI.'
      )
    }
  }
  return t(
    'The authorization request could not be loaded. Check your connection and try again.'
  )
}

export function AuthorizationConsent(props: { request: string }) {
  const { t, i18n } = useTranslation()
  const user = useAuthStore((state) => state.auth.user)
  const [navigationBlocked, setNavigationBlocked] = useState(false)
  const previewQuery = useQuery({
    queryKey: ['oauth-authorization', props.request],
    queryFn: () => getOAuthAuthorizationPreview(props.request),
    enabled: props.request.length > 0,
    retry: false,
    staleTime: 0,
  })
  const decisionMutation = useMutation({
    mutationFn: (approve: boolean) =>
      decideOAuthAuthorization(props.request, approve),
    onSuccess: (decision) => {
      if (!isSafeOAuthDecisionRedirect(decision.redirect_uri)) {
        setNavigationBlocked(true)
        return
      }
      window.location.assign(decision.redirect_uri)
    },
  })

  const title = t('Authorize lmm-api-rs')
  const description = t(
    'Review the access requested by the LMM API client on this device.'
  )

  if (props.request.length === 0) {
    return (
      <OAuthPageShell
        icon={LockKeyhole}
        title={title}
        description={description}
      >
        <Card>
          <ErrorState
            className='min-h-[20rem]'
            title={t('Authorization request missing')}
            description={t(
              'Start login again from lmm-api-rs to create a new authorization request.'
            )}
            action={
              <Button variant='outline' size='sm' render={<Link to='/' />}>
                {t('Return home')}
              </Button>
            }
          />
        </Card>
      </OAuthPageShell>
    )
  }

  if (previewQuery.isLoading) {
    return (
      <OAuthPageShell
        icon={LockKeyhole}
        title={title}
        description={description}
      >
        <AuthorizationLoading />
      </OAuthPageShell>
    )
  }

  if (previewQuery.isError || !previewQuery.data) {
    return (
      <OAuthPageShell
        icon={LockKeyhole}
        title={title}
        description={description}
      >
        <Card>
          <ErrorState
            className='min-h-[20rem]'
            title={t('Authorization request unavailable')}
            description={getErrorDescription(previewQuery.error, t)}
            onRetry={() => void previewQuery.refetch()}
          />
        </Card>
      </OAuthPageShell>
    )
  }

  const callbackLabel = getLoopbackCallbackLabel(
    previewQuery.data.redirect_uri
  )
  const invalidCallback = callbackLabel == null
  const mutationError = decisionMutation.isError || navigationBlocked
  const expiresDate = new Date(previewQuery.data.expires_at)
  const expiresAt = Number.isNaN(expiresDate.getTime())
    ? '—'
    : new Intl.DateTimeFormat(i18n.language, {
        hour: 'numeric',
        minute: '2-digit',
      }).format(expiresDate)

  return (
    <OAuthPageShell icon={LockKeyhole} title={title} description={description}>
      <Card>
        <CardHeader className='border-b'>
          <CardTitle>{previewQuery.data.client_name}</CardTitle>
          <CardDescription>
            {t('Signed in as {{account}}', {
              account:
                user?.display_name || user?.username || user?.email || '—',
            })}
          </CardDescription>
        </CardHeader>
        <CardContent className='space-y-4'>
          <div className='space-y-2.5'>
            <p className='text-sm font-medium'>{t('Requested access')}</p>
            <ul className='space-y-3' aria-label={t('Requested access')}>
              {previewQuery.data.scopes.map((scope) => {
                const copy = getScopeCopy(scope, t)
                return (
                  <li key={scope} className='flex gap-3'>
                    <copy.Icon
                      className='text-primary mt-0.5 size-4 shrink-0'
                      aria-hidden='true'
                    />
                    <div className='min-w-0 space-y-0.5'>
                      <p className='text-sm font-medium'>{copy.title}</p>
                      <p className='text-muted-foreground text-xs leading-relaxed'>
                        {copy.description}
                      </p>
                    </div>
                  </li>
                )
              })}
            </ul>
          </div>

          <Separator />

          <Alert>
            <MonitorSmartphone className='size-4' aria-hidden='true' />
            <AlertTitle>{t('Returns only to this device')}</AlertTitle>
            <AlertDescription>
              {callbackLabel
                ? t('After your decision, this tab returns to {{address}}.', {
                    address: callbackLabel,
                  })
                : t('The callback address is not a safe local address.')}{' '}
              {t('Tokens and API Keys are never shown on this page.')}
            </AlertDescription>
          </Alert>

          {mutationError && (
            <Alert variant='destructive'>
              <AlertTriangle className='size-4' aria-hidden='true' />
              <AlertTitle>
                {navigationBlocked
                  ? t('Unsafe callback blocked')
                  : t('Could not save your decision')}
              </AlertTitle>
              <AlertDescription>
                {navigationBlocked
                  ? t(
                      'The server returned a non-local callback. No authorization data was sent there.'
                    )
                  : t(
                      'The request may have expired or already been used. Start login again from the CLI.'
                    )}
              </AlertDescription>
            </Alert>
          )}

          <p className='text-muted-foreground text-xs'>
            {t('This request expires at {{time}}.', { time: expiresAt })}
          </p>
        </CardContent>
        {invalidCallback || navigationBlocked ? (
          <CardFooter>
            <Button
              variant='outline'
              size='lg'
              className='w-full'
              render={<Link to='/' />}
            >
              {t('Return home')}
            </Button>
          </CardFooter>
        ) : (
          <OAuthDecisionActions
            approveLabel={t('Allow access')}
            denyLabel={t('Deny')}
            pending={decisionMutation.isPending}
            pendingDecision={decisionMutation.variables}
            onApprove={() => decisionMutation.mutate(true)}
            onDeny={() => decisionMutation.mutate(false)}
          />
        )}
      </Card>
    </OAuthPageShell>
  )
}
