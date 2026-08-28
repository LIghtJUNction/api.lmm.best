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
import { useMutation } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import {
  AlertTriangle,
  CheckCircle2,
  CircleX,
  KeyRound,
  ShieldCheck,
} from 'lucide-react'
import { useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useAuthStore } from '@/stores/auth-store'

import { decideOAuthDevice } from './api'
import { OAuthDecisionActions } from './oauth-decision-actions'
import { OAuthPageShell } from './oauth-page-shell'
import {
  isCompleteOAuthDeviceCode,
  normalizeOAuthDeviceCode,
} from './oauth-utils'

export function DeviceAuthorization(props: { userCode?: string }) {
  const { t } = useTranslation()
  const user = useAuthStore((state) => state.auth.user)
  const [userCode, setUserCode] = useState(() =>
    normalizeOAuthDeviceCode(props.userCode ?? '')
  )
  const [completedDecision, setCompletedDecision] = useState<boolean | null>(
    null
  )
  const decisionMutation = useMutation({
    mutationFn: (approve: boolean) => decideOAuthDevice(userCode, approve),
    onSuccess: (result) => setCompletedDecision(result.approved),
  })

  const complete = isCompleteOAuthDeviceCode(userCode)
  const title = t('Connect lmm-api-rs')
  const description = t(
    'Enter the code shown by the CLI to connect it to your account.'
  )

  function approve(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (complete && !decisionMutation.isPending) {
      decisionMutation.mutate(true)
    }
  }

  if (completedDecision != null) {
    const CompletionIcon = completedDecision ? CheckCircle2 : CircleX
    return (
      <OAuthPageShell
        icon={ShieldCheck}
        title={title}
        description={description}
      >
        <Card>
          <CardContent className='flex min-h-72 flex-col items-center justify-center gap-4 py-10 text-center'>
            <div
              className={
                completedDecision
                  ? 'bg-success/10 text-success flex size-12 items-center justify-center rounded-full'
                  : 'bg-destructive/10 text-destructive flex size-12 items-center justify-center rounded-full'
              }
            >
              <CompletionIcon className='size-6' aria-hidden='true' />
            </div>
            <div className='space-y-1.5'>
              <h3 className='text-lg font-semibold'>
                {completedDecision
                  ? t('Device connected')
                  : t('Connection denied')}
              </h3>
              <p className='text-muted-foreground text-sm text-pretty'>
                {completedDecision
                  ? t(
                      'Return to the terminal. lmm-api-rs will finish signing in automatically.'
                    )
                  : t(
                      'No access was granted. You can close this tab or start again from the CLI.'
                    )}
              </p>
            </div>
            <Button variant='outline' render={<Link to='/' />}>
              {t('Return home')}
            </Button>
          </CardContent>
        </Card>
      </OAuthPageShell>
    )
  }

  return (
    <OAuthPageShell icon={KeyRound} title={title} description={description}>
      <Card>
        <form onSubmit={approve}>
          <CardHeader className='border-b'>
            <CardTitle>{t('Confirm your device code')}</CardTitle>
            <CardDescription>
              {t('Signed in as {{account}}', {
                account:
                  user?.display_name || user?.username || user?.email || '—',
              })}
            </CardDescription>
          </CardHeader>
          <CardContent className='space-y-4'>
            <div className='space-y-2'>
              <Label htmlFor='oauth-device-code'>{t('Device code')}</Label>
              <Input
                id='oauth-device-code'
                value={userCode}
                autoFocus
                autoComplete='one-time-code'
                autoCapitalize='characters'
                spellCheck={false}
                maxLength={9}
                placeholder='ABCD-EFGH'
                className='h-12 text-center font-mono text-xl tracking-[0.22em] uppercase md:text-xl'
                aria-invalid={decisionMutation.isError}
                aria-describedby='oauth-device-code-help'
                disabled={decisionMutation.isPending}
                onChange={(event) => {
                  setUserCode(normalizeOAuthDeviceCode(event.target.value))
                  decisionMutation.reset()
                }}
              />
              <p
                id='oauth-device-code-help'
                className='text-muted-foreground text-xs'
              >
                {t('The code contains eight letters or numbers and expires soon.')}
              </p>
            </div>

            <Alert>
              <ShieldCheck className='size-4' aria-hidden='true' />
              <AlertTitle>{t('Only approve a code you requested')}</AlertTitle>
              <AlertDescription>
                {t(
                  'LMM Forge will never ask you to share this code with another person.'
                )}
              </AlertDescription>
            </Alert>

            {decisionMutation.isError && (
              <Alert variant='destructive'>
                <AlertTriangle className='size-4' aria-hidden='true' />
                <AlertTitle>{t('Could not confirm this code')}</AlertTitle>
                <AlertDescription>
                  {t(
                    'The code is invalid, expired, or already used. Check the terminal and try again.'
                  )}
                </AlertDescription>
              </Alert>
            )}
          </CardContent>
          <OAuthDecisionActions
            approveLabel={t('Connect device')}
            denyLabel={t('Deny')}
            approveType='submit'
            disabled={!complete}
            pending={decisionMutation.isPending}
            pendingDecision={decisionMutation.variables}
            onDeny={() => decisionMutation.mutate(false)}
          />
        </form>
      </Card>
    </OAuthPageShell>
  )
}
