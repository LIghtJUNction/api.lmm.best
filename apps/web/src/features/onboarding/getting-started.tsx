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
import { useTranslation } from 'react-i18next'

import { SectionPageLayout } from '@/components/layout'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Separator } from '@/components/ui/separator'
import { getOnboardingState } from '@/lib/console-activation'
import { cn } from '@/lib/utils'
import { useAuthStore } from '@/stores/auth-store'

import { useAuthUserRefresh } from './use-auth-user-refresh'

export function GettingStarted() {
  const { t } = useTranslation()
  useAuthUserRefresh()
  const user = useAuthStore((state) => state.auth.user)
  const onboarding = getOnboardingState(user)
  const trustLevel = user?.trust_level_info?.level ?? 0

  const primaryCommand =
    onboarding.stage === 'activate'
      ? {
          to: '/wallet' as const,
          label: t('Add funds'),
          icon: Wallet,
        }
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
  const PrimaryIcon = primaryCommand.icon
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
      description: t('Any successful external top-up activates access.'),
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
                  {t(
                    'Access becomes available after a successful external payment.'
                  )}
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

          <section className='flex flex-col gap-4 border-y px-5 py-6 sm:flex-row sm:items-center sm:justify-between sm:px-8 sm:py-7'>
            <div className='max-w-2xl'>
              <p className='text-sm font-semibold'>{t('Next step')}</p>
              <p className='text-muted-foreground mt-1 text-sm leading-6'>
                {onboarding.stage === 'activate'
                  ? t('Activate access with any successful external top-up.')
                  : onboarding.stage === 'credential'
                    ? t('Create a credential to continue setup.')
                    : onboarding.stage === 'first_request'
                      ? t('Send one request to complete setup.')
                      : t('Go to your dashboard to continue.')}
              </p>
            </div>
            <Button
              className='w-full sm:w-auto'
              size='lg'
              render={<Link to={primaryCommand.to} />}
            >
              <PrimaryIcon data-icon='inline-start' aria-hidden='true' />
              {primaryCommand.label}
              <ArrowRight data-icon='inline-end' aria-hidden='true' />
            </Button>
          </section>
        </div>
      </SectionPageLayout.Content>
    </SectionPageLayout>
  )
}
