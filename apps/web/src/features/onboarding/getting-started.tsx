/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
*/
import { Link } from '@tanstack/react-router'
import {
  ArrowRight,
  Check,
  KeyRound,
  LayoutDashboard,
  MessageCircleQuestion,
  Wallet,
} from 'lucide-react'
import { type FormEvent, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { SectionPageLayout } from '@/components/layout'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Progress } from '@/components/ui/progress'
import { Separator } from '@/components/ui/separator'
import { requestAssistantOpen } from '@/features/assistant/assistant-events'
import { ChallengeList } from '@/features/forge/challenge-list'
import { useTopupInfo } from '@/features/wallet/hooks/use-topup-info'
import { getTopupAvailability } from '@/features/wallet/lib/payment'
import { getOnboardingState } from '@/lib/console-activation'
import { useAuthStore } from '@/stores/auth-store'

import { getDeveloperAccessRequest, type DeveloperAccessRequest } from './api'
import { claimOnboardingAssistantPrompt } from './pending-review-assistant'
import { useAuthUserRefresh } from './use-auth-user-refresh'

export function GettingStarted() {
  const { t } = useTranslation()
  useAuthUserRefresh()
  const user = useAuthStore((state) => state.auth.user)
  const onboarding = getOnboardingState(user)
  const trustLevel = user?.trust_level_info?.level ?? 0
  const [prompt, setPrompt] = useState('')
  const [accessRequest, setAccessRequest] =
    useState<DeveloperAccessRequest | null>(null)
  const [requestLoaded, setRequestLoaded] = useState(false)
  const { topupInfo, loading: topupLoading, error: topupError } = useTopupInfo()
  const topupAvailability = getTopupAvailability(topupInfo)

  useEffect(() => {
    if (onboarding.stage !== 'activate') {
      setRequestLoaded(true)
      return
    }
    let cancelled = false
    void getDeveloperAccessRequest()
      .then((request) => {
        if (!cancelled) setAccessRequest(request)
      })
      .catch(() => undefined)
      .finally(() => {
        if (!cancelled) setRequestLoaded(true)
      })
    return () => {
      cancelled = true
    }
  }, [onboarding.stage])

  const pendingRequestId =
    accessRequest?.status === 'pending' ? accessRequest.id : 0
  const userId = user?.id ?? 0
  useEffect(() => {
    if (!requestLoaded || onboarding.stage !== 'activate') return
    if (!claimOnboardingAssistantPrompt(userId, pendingRequestId)) return
    requestAssistantOpen('onboarding')
  }, [onboarding.stage, pendingRequestId, requestLoaded, userId])

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

  const submitPrompt = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const message = prompt.trim()
    if (!message) return
    requestAssistantOpen('onboarding', message)
  }

  const stageLabel = onboarding.activationComplete
    ? onboarding.stage === 'complete'
      ? t('Setup complete')
      : t('Continue setup')
    : t('L0 tutorial required')

  const tutorialSteps = [
    {
      complete: onboarding.activationComplete,
      title: t('Unlock L1 access'),
      description: t(
        'Add funds for automatic activation, or send a free explanation to an administrator for manual review.'
      ),
      preset: 'onboarding' as const,
    },
    {
      complete: onboarding.credentialComplete,
      title: t('Create API key'),
      description: t('Create your first developer credential.'),
      preset: 'api-key' as const,
    },
    {
      complete: onboarding.firstRequestComplete,
      title: t('Send first request'),
      description: t('Send one request to complete setup.'),
      preset: 'client-setup' as const,
    },
  ]
  const completedTutorialSteps = tutorialSteps.filter(
    (step) => step.complete
  ).length
  const currentTutorialStep = tutorialSteps.findIndex((step) => !step.complete)
  const tutorialProgress = (completedTutorialSteps / tutorialSteps.length) * 100

  return (
    <SectionPageLayout>
      <SectionPageLayout.Title>{t('Getting started')}</SectionPageLayout.Title>
      <SectionPageLayout.Content>
        <div className='mx-auto flex w-full max-w-4xl flex-col gap-6 pb-10 sm:gap-8 sm:pb-14'>
          <section className='bg-muted/30 border-y px-5 py-8 sm:px-8 sm:py-12'>
            <div className='flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between'>
              <div className='max-w-2xl'>
                <p className='text-muted-foreground text-sm font-medium'>
                  {t('One conversation to get started')}
                </p>
                <h3 className='mt-2 text-2xl font-semibold sm:text-3xl'>
                  {onboarding.activationComplete
                    ? t('Tell the AI assistant what you want to do')
                    : t('Tell the AI assistant what you want to build')}
                </h3>
                <p className='text-muted-foreground mt-3 text-sm leading-6'>
                  {onboarding.activationComplete
                    ? t(
                        'Ask for a setup guide, model ID, API key, usage report, plan comparison, or any other next step. The assistant can guide the action from here.'
                      )
                    : t(
                        'L0 accounts start here. The assistant will explain L1 activation, recharge options, the free review path, and then guide you through software setup.'
                      )}
                </p>
              </div>
              <div className='flex shrink-0 flex-wrap gap-2'>
                <Badge variant='outline'>
                  {t('L{{level}}', { level: trustLevel })}
                </Badge>
                <Badge
                  variant={
                    onboarding.activationComplete ? 'secondary' : 'outline'
                  }
                >
                  {stageLabel}
                </Badge>
              </div>
            </div>

            <form
              className='mt-7 flex flex-col gap-3 sm:flex-row'
              onSubmit={submitPrompt}
            >
              <Input
                value={prompt}
                onChange={(event) => setPrompt(event.target.value)}
                maxLength={4000}
                className='h-12 flex-1'
                placeholder={t(
                  'For example: help me activate L1 and configure CC Switch'
                )}
                aria-label={t('Tell the AI assistant what you need')}
              />
              <Button type='submit' size='lg' disabled={!prompt.trim()}>
                <MessageCircleQuestion
                  data-icon='inline-start'
                  aria-hidden='true'
                />
                {t('Start with AI assistant')}
                <ArrowRight data-icon='inline-end' aria-hidden='true' />
              </Button>
            </form>
            <div
              className='mt-3 flex flex-wrap gap-2'
              aria-label={t(
                'Choose a common question or ask anything about using LMM.'
              )}
            >
              {[
                t('What can I do while access is under review?'),
                t('Which option is the best value?'),
                t('What are my Base URL, model ID, and API key?'),
                t('How do I set up Claude Code or CC Switch?'),
              ].map((question) => (
                <Button
                  key={question}
                  type='button'
                  variant='outline'
                  size='sm'
                  className='h-auto min-h-9 whitespace-normal'
                  onClick={() => requestAssistantOpen(undefined, question)}
                >
                  {question}
                </Button>
              ))}
            </div>
            <p className='text-muted-foreground mt-3 text-xs leading-5'>
              {t(
                'Never paste a password, API key, session cookie, or other secret into the conversation.'
              )}
            </p>
          </section>

          <section
            className='border px-5 py-6 sm:px-8'
            aria-labelledby='getting-started-tutorial-title'
          >
            <div className='flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between'>
              <div>
                <h3
                  id='getting-started-tutorial-title'
                  className='text-sm font-semibold'
                >
                  {t('Three steps to get started')}
                </h3>
                <p className='text-muted-foreground mt-1 text-sm leading-6'>
                  {t(
                    'Complete these steps to finish the initial installation.'
                  )}
                </p>
              </div>
              <Badge
                variant={
                  onboarding.stage === 'complete' ? 'secondary' : 'outline'
                }
              >
                {completedTutorialSteps}/{tutorialSteps.length}
              </Badge>
            </div>

            <div className='mt-5 flex items-center gap-3'>
              <Progress
                value={tutorialProgress}
                aria-label={t('Three steps to get started')}
                className='flex-1'
              />
              <span className='text-muted-foreground shrink-0 text-xs tabular-nums'>
                {Math.round(tutorialProgress)}%
              </span>
            </div>

            <ol className='mt-6 grid gap-3 lg:grid-cols-3'>
              {tutorialSteps.map((step, index) => {
                const isCurrent = index === currentTutorialStep
                let markerClass =
                  'text-muted-foreground border-muted-foreground/40 flex size-7 shrink-0 items-center justify-center rounded-full border text-sm font-semibold'
                let statusLabel = t('Pending')
                if (isCurrent) {
                  markerClass =
                    'border-primary text-primary flex size-7 shrink-0 items-center justify-center rounded-full border text-sm font-semibold'
                  statusLabel = t('Current step')
                }
                if (step.complete) {
                  markerClass =
                    'bg-primary text-primary-foreground flex size-7 shrink-0 items-center justify-center rounded-full'
                  statusLabel = t('Completed')
                }
                return (
                  <li
                    key={step.title}
                    className={
                      isCurrent
                        ? 'border-primary/50 bg-primary/5 flex min-h-40 flex-col gap-4 border p-4'
                        : 'bg-muted/20 flex min-h-40 flex-col gap-4 border p-4'
                    }
                  >
                    <div className='flex items-start gap-3'>
                      <span className={markerClass} aria-hidden='true'>
                        {step.complete ? (
                          <Check className='size-4' />
                        ) : (
                          index + 1
                        )}
                      </span>
                      <div className='min-w-0 flex-1'>
                        <p className='text-sm font-medium'>{step.title}</p>
                        <p className='text-muted-foreground mt-1 text-xs leading-5'>
                          {step.description}
                        </p>
                      </div>
                    </div>
                    <div className='mt-auto flex items-center justify-between gap-2'>
                      <Badge variant={step.complete ? 'secondary' : 'outline'}>
                        {statusLabel}
                      </Badge>
                      {isCurrent ? (
                        <Button
                          type='button'
                          variant='ghost'
                          size='sm'
                          onClick={() => requestAssistantOpen(step.preset)}
                        >
                          {t('Continue')}
                          <ArrowRight
                            data-icon='inline-end'
                            aria-hidden='true'
                          />
                        </Button>
                      ) : null}
                    </div>
                  </li>
                )
              })}
            </ol>
          </section>

          <section className='border px-5 py-5 sm:px-8'>
            <div className='flex items-start gap-3'>
              <span className='bg-primary text-primary-foreground flex size-9 shrink-0 items-center justify-center rounded-full'>
                <MessageCircleQuestion aria-hidden='true' />
              </span>
              <div className='min-w-0'>
                <h3 className='text-sm font-semibold'>
                  {t('What the assistant can do')}
                </h3>
                <p className='text-muted-foreground mt-1 text-sm leading-6'>
                  {t(
                    'It can compare packages and discounts, calculate cost, show model IDs and Base URL, create a key after confirmation, teach Claude/Codex/CC Switch setup, analyze historical calls, explain invitations and bounties, or forward a free request to an administrator.'
                  )}
                </p>
              </div>
            </div>
          </section>

          {!onboarding.activationComplete ? (
            <section className='border px-5 py-6 sm:px-8'>
              <div className='flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between'>
                <div className='max-w-2xl'>
                  <h3 className='text-sm font-semibold'>
                    {t('Choose how to unlock access')}
                  </h3>
                  <p className='text-muted-foreground mt-2 text-sm leading-6'>
                    {activationMessage}
                  </p>
                  {accessRequest?.status === 'pending' ? (
                    <p className='bg-muted/30 mt-4 border px-3 py-2 text-xs leading-5'>
                      {t(
                        'Your free unlock request is waiting for administrator review.'
                      )}
                    </p>
                  ) : null}
                </div>
                <div className='flex shrink-0 flex-wrap gap-2'>
                  {!topupLoading &&
                  !topupError &&
                  topupAvailability.hasPaymentMethod ? (
                    <Button render={<Link to='/wallet' />}>
                      <Wallet data-icon='inline-start' aria-hidden='true' />
                      {t('Recharge to unlock')}
                    </Button>
                  ) : null}
                  <Button
                    type='button'
                    variant='outline'
                    onClick={() => requestAssistantOpen('onboarding')}
                  >
                    {t('Ask AI to submit a free request')}
                  </Button>
                </div>
              </div>
            </section>
          ) : (
            <section className='border px-5 py-6 sm:px-8'>
              <div className='flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between'>
                <div>
                  <h3 className='text-sm font-semibold'>
                    {t('Continue with your first integration')}
                  </h3>
                  <p className='text-muted-foreground mt-1 text-sm leading-6'>
                    {t(
                      'Ask the assistant to create a key, configure a client, or send a first test request.'
                    )}
                  </p>
                </div>
                <Button
                  variant='outline'
                  onClick={() => requestAssistantOpen('client-setup')}
                >
                  <KeyRound data-icon='inline-start' aria-hidden='true' />
                  {t('Open setup guide')}
                </Button>
              </div>
            </section>
          )}

          <section className='border-y px-5 py-5 sm:px-8'>
            <div className='flex flex-wrap items-center justify-between gap-3'>
              <div>
                <h3 className='text-sm font-semibold'>{t('Quick links')}</h3>
                <p className='text-muted-foreground mt-1 text-sm'>
                  {t('You can return to this guided conversation at any time.')}
                </p>
              </div>
              <div className='flex flex-wrap gap-2'>
                {onboarding.activationComplete ? (
                  <Button variant='outline' render={<Link to='/dashboard' />}>
                    <LayoutDashboard
                      data-icon='inline-start'
                      aria-hidden='true'
                    />
                    {t('Dashboard')}
                  </Button>
                ) : null}
                <Button
                  variant='outline'
                  render={<Link to='/open-source-bounties' />}
                >
                  {t('Open-source bounties')}
                </Button>
              </div>
            </div>
          </section>

          <Separator />
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
