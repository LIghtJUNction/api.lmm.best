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
import {
  ArrowRight,
  Check,
  Circle,
  KeyRound,
  LayoutDashboard,
  Send,
  Wallet,
} from 'lucide-react'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { SectionPageLayout } from '@/components/layout'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Separator } from '@/components/ui/separator'
import { Textarea } from '@/components/ui/textarea'
import { ChallengeList } from '@/features/forge/challenge-list'
import { useTopupInfo } from '@/features/wallet/hooks/use-topup-info'
import { getTopupAvailability } from '@/features/wallet/lib/payment'
import { getOnboardingState } from '@/lib/console-activation'
import { cn } from '@/lib/utils'
import { useAuthStore } from '@/stores/auth-store'

import {
  getDeveloperAccessRequest,
  submitDeveloperAccessRequest,
  type DeveloperAccessRequest,
} from './api'
import { useAuthUserRefresh } from './use-auth-user-refresh'

export function GettingStarted() {
  const { t } = useTranslation()
  useAuthUserRefresh()
  const user = useAuthStore((state) => state.auth.user)
  const onboarding = getOnboardingState(user)
  const trustLevel = user?.trust_level_info?.level ?? 0
  const [accessRequest, setAccessRequest] =
    useState<DeveloperAccessRequest | null>(null)
  const [requestReason, setRequestReason] = useState('')
  const [requestLoading, setRequestLoading] = useState(false)
  const [requestLoaded, setRequestLoaded] = useState(false)
  const { topupInfo, loading: topupLoading, error: topupError } = useTopupInfo()
  const topupAvailability = getTopupAvailability(topupInfo)
  useEffect(() => {
    if (onboarding.stage !== 'activate') return
    let cancelled = false
    getDeveloperAccessRequest()
      .then((request) => {
        if (!cancelled) setAccessRequest(request)
      })
      .catch(() => {
        // The request form remains usable when a legacy backend has not yet
        // mounted the optional status endpoint.
      })
      .finally(() => {
        if (!cancelled) setRequestLoaded(true)
      })
      .catch(() => {
        // Keep the optional request status probe non-blocking.
      })
    return () => {
      cancelled = true
    }
  }, [onboarding.stage])
  const activationMessage = topupLoading
    ? t('Checking payment availability...')
    : topupError
      ? t(
          'Payment availability could not be verified. You can submit an administrator unlock request instead.'
        )
      : !topupAvailability.hasPaymentMethod
        ? t(
            'Online payment is temporarily unavailable. You can submit an administrator unlock request instead.'
          )
        : t(
            'Choose either automatic activation after adding funds or an administrator unlock request.'
          )
  const activationCommand = topupLoading
    ? null
    : topupError || !topupAvailability.hasPaymentMethod
      ? null
      : { to: '/wallet' as const, label: t('Add funds'), icon: Wallet }

  const submitUnlockRequest = async () => {
    if (requestLoading || accessRequest?.status === 'pending') return
    setRequestLoading(true)
    try {
      const request = await submitDeveloperAccessRequest(requestReason.trim())
      setAccessRequest(request)
      setRequestReason('')
      toast.success(t('Unlock request submitted'))
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : t('Unable to submit unlock request')
      )
    } finally {
      setRequestLoading(false)
    }
  }

  const primaryCommand =
    onboarding.stage === 'activate'
      ? activationCommand
      : onboarding.stage === 'credential'
        ? {
            to: '/keys' as const,
            label: t('Create credential'),
            icon: KeyRound,
          }
        : onboarding.stage === 'first_request'
          ? {
              to: '/playground' as const,
              label: t('Open playground'),
              icon: Send,
            }
          : {
              to: '/dashboard' as const,
              label: t('Open dashboard'),
              icon: LayoutDashboard,
            }
  const PrimaryIcon = primaryCommand?.icon
  const steps = [
    {
      id: 'account',
      title: t('Account created'),
      description: t('Your account is ready.'),
      complete: true,
      icon: Check,
    },
    {
      id: 'activate',
      title: t('Activate access'),
      description: activationMessage,
      complete: onboarding.activationComplete,
      icon: Wallet,
    },
    {
      id: 'credential',
      title: t('Create credential'),
      description: t('Set up a credential for your account.'),
      complete: onboarding.credentialComplete,
      icon: KeyRound,
    },
    {
      id: 'first_request',
      title: t('Send first request'),
      description: t('Complete one request to finish setup.'),
      complete: onboarding.firstRequestComplete,
      icon: Send,
    },
  ] as const

  return (
    <SectionPageLayout>
      <SectionPageLayout.Title>{t('Getting started')}</SectionPageLayout.Title>
      <SectionPageLayout.Content>
        <div className='mx-auto flex w-full max-w-5xl flex-col gap-6 pb-10 sm:gap-8 sm:pb-14'>
          <section className='bg-muted/30 border-y px-5 py-7 sm:px-8 sm:py-10'>
            <div className='flex flex-col gap-6 sm:flex-row sm:items-end sm:justify-between'>
              <div className='max-w-2xl'>
                <p className='text-muted-foreground text-sm font-medium'>
                  {t('Account setup')}
                </p>
                <h3 className='mt-2 text-2xl font-semibold sm:text-3xl'>
                  {onboarding.stage === 'complete'
                    ? t('Your account is ready.')
                    : t('Complete your account setup')}
                </h3>
                <p className='text-muted-foreground mt-3 max-w-xl text-sm leading-6'>
                  {activationMessage}
                </p>
              </div>
              <div className='flex shrink-0 flex-wrap items-center gap-2'>
                <Badge variant='outline'>
                  {t('Level {{level}}', { level: trustLevel })}
                </Badge>
                <Badge
                  variant={
                    onboarding.activationComplete ? 'secondary' : 'outline'
                  }
                >
                  {onboarding.activationComplete
                    ? t('Access activated')
                    : t('Activation pending')}
                </Badge>
              </div>
            </div>
          </section>

          <section className='border'>
            <div className='flex flex-wrap items-center justify-between gap-3 px-5 py-4 sm:px-6'>
              <div>
                <h3 className='text-sm font-semibold'>{t('Setup progress')}</h3>
                <p className='text-muted-foreground mt-1 text-sm'>
                  {t('Follow the account milestones below.')}
                </p>
              </div>
              <Badge variant='outline'>
                {onboarding.stage === 'complete'
                  ? t('Complete')
                  : t('Current step: {{step}}', {
                      step: steps.find((step) => step.id === onboarding.stage)
                        ?.title,
                    })}
              </Badge>
            </div>
            <Separator />
            <ol className='grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4'>
              {steps.map((step) => {
                const StepIcon = step.icon
                const current = step.id === onboarding.stage

                return (
                  <li
                    key={step.id}
                    aria-current={current ? 'step' : undefined}
                    className={cn(
                      'min-h-36 border-b px-5 py-5 sm:px-6 lg:border-b-0 lg:border-r last:border-b-0 lg:last:border-r-0',
                      current && 'bg-muted/50'
                    )}
                  >
                    <div className='flex items-start gap-3'>
                      <div
                        className={cn(
                          'flex size-8 shrink-0 items-center justify-center rounded-full border',
                          step.complete &&
                            'bg-primary text-primary-foreground border-primary'
                        )}
                      >
                        {step.complete ? (
                          <Check aria-hidden='true' className='size-4' />
                        ) : (
                          <Circle aria-hidden='true' className='size-3' />
                        )}
                      </div>
                      <div className='min-w-0'>
                        <div className='flex items-center gap-2'>
                          <StepIcon
                            aria-hidden='true'
                            className='size-4 shrink-0'
                          />
                          <p className='text-sm font-semibold'>{step.title}</p>
                        </div>
                        <p className='text-muted-foreground mt-2 text-sm leading-5'>
                          {step.description}
                        </p>
                        <span className='sr-only'>
                          {step.complete ? t('Completed') : t('Pending')}
                        </span>
                      </div>
                    </div>
                    {current && (
                      <Badge className='mt-4' variant='secondary'>
                        {t('Current step')}
                      </Badge>
                    )}
                  </li>
                )
              })}
            </ol>
          </section>

          {onboarding.stage === 'activate' && requestLoaded ? (
            <section className='border px-5 py-6 sm:px-8 sm:py-7'>
              <div className='max-w-2xl'>
                <h3 className='text-sm font-semibold'>
                  {t('Choose how to unlock access')}
                </h3>
                <p className='text-muted-foreground mt-2 text-sm leading-6'>
                  {t(
                    'Adding funds is optional. You may request administrator review instead; an approved request unlocks L1 access without a charge.'
                  )}
                </p>
              </div>
              {accessRequest?.status === 'pending' ? (
                <div className='bg-muted/30 text-muted-foreground mt-5 border px-4 py-3 text-sm leading-6'>
                  {t(
                    'Your unlock request is waiting for administrator review. You can continue using the recharge and open-source bounty pages.'
                  )}
                </div>
              ) : (
                <div className='mt-5 flex flex-col gap-3'>
                  {accessRequest?.status === 'rejected' ? (
                    <div className='bg-muted/30 text-muted-foreground border px-4 py-3 text-sm leading-6'>
                      <p>
                        {t('Your previous unlock request was not approved.')}
                      </p>
                      {accessRequest.admin_note ? (
                        <p className='mt-1'>
                          {t('Administrator note: {{note}}', {
                            note: accessRequest.admin_note,
                          })}
                        </p>
                      ) : null}
                    </div>
                  ) : null}
                  <Textarea
                    value={requestReason}
                    onChange={(event) => setRequestReason(event.target.value)}
                    placeholder={t(
                      'Explain why you need developer access (optional)'
                    )}
                    maxLength={2000}
                    rows={3}
                  />
                  <div className='flex flex-wrap items-center gap-3'>
                    <Button
                      onClick={submitUnlockRequest}
                      disabled={requestLoading}
                    >
                      {requestLoading
                        ? t('Submitting...')
                        : t('Submit unlock request')}
                    </Button>
                    <span className='text-muted-foreground text-xs'>
                      {t(
                        'An administrator will review the request before access is enabled.'
                      )}
                    </span>
                  </div>
                </div>
              )}
            </section>
          ) : null}

          <section className='flex flex-col gap-4 border-y px-5 py-6 sm:flex-row sm:items-center sm:justify-between sm:px-8 sm:py-7'>
            <div className='max-w-2xl'>
              <p className='text-sm font-semibold'>{t('Next step')}</p>
              <p className='text-muted-foreground mt-1 text-sm leading-6'>
                {onboarding.stage === 'activate'
                  ? activationMessage
                  : onboarding.stage === 'credential'
                    ? t('Create a credential to continue setup.')
                    : onboarding.stage === 'first_request'
                      ? t('Send one request to complete setup.')
                      : t('Go to your dashboard to continue.')}
              </p>
            </div>
            {primaryCommand && PrimaryIcon ? (
              <Button
                className='w-full sm:w-auto'
                size='lg'
                render={<Link to={primaryCommand.to} />}
              >
                <PrimaryIcon data-icon='inline-start' aria-hidden='true' />
                {primaryCommand.label}
                <ArrowRight data-icon='inline-end' aria-hidden='true' />
              </Button>
            ) : null}
          </section>

          <ChallengeList
            limit={3}
            hideWhenUnavailable
            heading={t('Optional open-source challenges')}
            description={t(
              'Contributions can earn account credit, but they do not activate access.'
            )}
          />
        </div>
      </SectionPageLayout.Content>
    </SectionPageLayout>
  )
}
