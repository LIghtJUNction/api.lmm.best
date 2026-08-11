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
*/
import { useQuery } from '@tanstack/react-query'
import {
  Activity,
  AlertTriangle,
  BookOpenCheck,
  CircleDollarSign,
  Eye,
  FileWarning,
  LockKeyhole,
  ShieldCheck,
} from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { ForgePublicShell } from '@/features/forge/forge-public-shell'
import { formatNumber } from '@/lib/format'

import { SECURITY_OVERVIEW_ENDPOINT, getSecurityOverview } from './api'
import type {
  SecurityChargeAction,
  SecurityChargeRule,
  SecurityOverview,
  SecurityRiskMetric,
} from './types'

type PublicRule = {
  icon: typeof ShieldCheck
  title: string
  description: string
}

const PUBLIC_RULES: PublicRule[] = [
  {
    icon: ShieldCheck,
    title: 'High-risk harm',
    description:
      'Requests that meaningfully facilitate serious physical, digital, or financial harm are not allowed.',
  },
  {
    icon: Eye,
    title: 'Privacy and personal data',
    description:
      "Do not use the service to expose, infer, or misuse another person's sensitive personal information.",
  },
  {
    icon: FileWarning,
    title: 'Fraud, abuse, and evasion',
    description:
      'Requests intended to deceive, defraud, bypass safeguards, or evade enforcement may be blocked.',
  },
  {
    icon: LockKeyhole,
    title: 'High-impact decisions',
    description:
      "Do not use outputs as the sole basis for decisions that materially affect a person's rights, access, safety, or essential services.",
  },
]

const DETECTION_PRINCIPLES = [
  {
    icon: Activity,
    title: 'Detection and enforcement',
    description:
      'The platform may combine rule matching, request context, and service signals to identify risk.',
  },
  {
    icon: ShieldCheck,
    title: 'Block before upstream',
    description:
      'Requests can be stopped before an upstream model call when a rule is triggered.',
  },
  {
    icon: BookOpenCheck,
    title: 'Review and appeal',
    description:
      'If you believe a request was blocked incorrectly, contact support with the request ID. Do not include secrets in a support ticket.',
  },
]

const METRIC_LABELS: Record<string, string> = {
  requests_scanned: 'Requests scanned',
  requests_blocked: 'Requests blocked',
  requests_flagged: 'Requests flagged',
  charge_events: 'Charge events',
}

const CHARGE_ACTION_LABELS: Record<SecurityChargeAction, string> = {
  block: 'Blocked',
  review: 'Review',
  deduct: 'Deduction',
  suspend: 'Account action',
}

const numberFormatter = new Intl.NumberFormat()

function metricLabel(
  metric: SecurityRiskMetric,
  t: ReturnType<typeof useTranslation>['t']
) {
  if (metric.label) return metric.label
  const label = METRIC_LABELS[metric.key]
  return label ? t(label) : metric.key
}

function formatMetricValue(metric: SecurityRiskMetric): string {
  if (metric.unit === 'percent') return `${metric.value}%`
  return numberFormatter.format(metric.value)
}

function formatChargeAmount(
  charge: SecurityChargeRule,
  t: ReturnType<typeof useTranslation>['t']
): string {
  if (typeof charge.amount !== 'number' || !charge.currency) {
    return t('Not published')
  }

  return `${charge.currency} ${formatNumber(charge.amount)}`
}

function UnavailableState({
  title,
  description,
  icon: Icon = AlertTriangle,
}: {
  title: string
  description: string
  icon?: typeof AlertTriangle
}) {
  return (
    <div className='border-border/70 bg-muted/20 rounded-xl border border-dashed p-6'>
      <div className='flex items-start gap-3'>
        <Icon className='text-muted-foreground mt-0.5 size-5 shrink-0' />
        <div className='space-y-1'>
          <p className='text-sm font-medium'>{title}</p>
          <p className='text-muted-foreground text-sm leading-6'>
            {description}
          </p>
        </div>
      </div>
    </div>
  )
}

function MetricsPanel({
  overview,
  isLoading,
}: {
  overview?: SecurityOverview
  isLoading: boolean
}) {
  const { t } = useTranslation()
  const metrics = overview?.metrics ?? []

  if (isLoading) {
    return (
      <div className='grid gap-3 sm:grid-cols-2 xl:grid-cols-4'>
        {Array.from({ length: 4 }, (_, index) => (
          <Card key={index} size='sm'>
            <CardHeader>
              <Skeleton className='h-4 w-28' />
            </CardHeader>
            <CardContent>
              <Skeleton className='h-8 w-20' />
            </CardContent>
          </Card>
        ))}
      </div>
    )
  }

  if (metrics.length === 0) {
    return (
      <UnavailableState
        title={t('No live risk metrics are available yet.')}
        description={t(
          'The security statistics endpoint has not returned data. No numbers are fabricated in this view.'
        )}
      />
    )
  }

  return (
    <div className='grid gap-3 sm:grid-cols-2 xl:grid-cols-4'>
      {metrics.map((metric) => (
        <Card key={metric.key} size='sm'>
          <CardHeader>
            <CardDescription>{metricLabel(metric, t)}</CardDescription>
          </CardHeader>
          <CardContent>
            <p className='text-3xl font-semibold tracking-tight tabular-nums'>
              {formatMetricValue(metric)}
            </p>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}

function ChargeSchedule({
  charges,
}: {
  charges?: SecurityChargeRule[] | null
}) {
  const { t } = useTranslation()

  if (!charges || charges.length === 0) {
    return (
      <UnavailableState
        title={t('No public violation charge schedule is available yet.')}
        description={t(
          'When the backend publishes the charge schedule, each rule will show its scope, action, and amount here.'
        )}
        icon={CircleDollarSign}
      />
    )
  }

  return (
    <div className='overflow-x-auto rounded-xl border'>
      <table className='w-full min-w-[38rem] text-left text-sm'>
        <thead className='bg-muted/40 text-muted-foreground border-b text-xs'>
          <tr>
            <th className='px-4 py-3 font-medium'>{t('Rule')}</th>
            <th className='px-4 py-3 font-medium'>{t('Action')}</th>
            <th className='px-4 py-3 font-medium'>{t('Scope')}</th>
            <th className='px-4 py-3 text-right font-medium'>
              {t('Deduction')}
            </th>
          </tr>
        </thead>
        <tbody className='divide-border/70 divide-y'>
          {charges.map((charge) => {
            const action =
              CHARGE_ACTION_LABELS[charge.action as SecurityChargeAction] ??
              charge.action
            return (
              <tr
                key={charge.id}
                className='hover:bg-muted/20 transition-colors'
              >
                <td className='px-4 py-3 align-top'>{charge.rule}</td>
                <td className='px-4 py-3 align-top'>
                  <Badge variant='outline'>{t(action)}</Badge>
                </td>
                <td className='text-muted-foreground px-4 py-3 align-top'>
                  {charge.scope || t('Not published')}
                </td>
                <td className='px-4 py-3 text-right align-top font-mono tabular-nums'>
                  {formatChargeAmount(charge, t)}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

export function Security() {
  const { t } = useTranslation()
  const securityQuery = useQuery({
    queryKey: ['security-overview'],
    queryFn: getSecurityOverview,
    retry: false,
    refetchOnWindowFocus: false,
    staleTime: 60_000,
  })
  const overview = securityQuery.data?.data
  const hasLivePolicy = Boolean(securityQuery.data?.success && overview)

  return (
    <ForgePublicShell>
      <main className='mx-auto max-w-7xl px-5 pt-32 pb-24 md:px-10 md:pt-40'>
        <div className='space-y-12'>
          <header className='max-w-4xl space-y-6'>
            <div className='flex items-center gap-3 text-xs font-bold tracking-[0.18em] uppercase'>
              <span className='bg-foreground size-2 rounded-full' />
              <span>{t('Safety center')}</span>
            </div>
            <div className='space-y-4'>
              <h1 className='font-serif text-5xl leading-[1.02] font-normal tracking-tight md:text-7xl'>
                {t('Security overview')}
              </h1>
              <p className='text-muted-foreground max-w-3xl text-base leading-7 md:text-lg'>
                {t(
                  'Understand how requests are screened, what happens when risk is detected, and how public charge rules are published.'
                )}
              </p>
            </div>
          </header>

          <Alert className='border-foreground/20 bg-foreground/[0.04]'>
            <ShieldCheck />
            <AlertTitle>{t('Public safety summary')}</AlertTitle>
            <AlertDescription>
              {t(
                "This page publishes the platform's current safety boundaries and transparent handling principles. Live metrics and charge schedules come from the server policy endpoint."
              )}
            </AlertDescription>
          </Alert>

          <p className='text-muted-foreground max-w-3xl text-xs leading-5'>
            {t(
              "This is a public summary of this site's configured safety rules. It is not official Anthropic policy, authorization, endorsement, or legal advice."
            )}
          </p>

          <section
            aria-labelledby='security-metrics-title'
            className='space-y-5'
          >
            <div className='flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between'>
              <div>
                <h2
                  id='security-metrics-title'
                  className='font-serif text-3xl font-normal tracking-tight'
                >
                  {t('Risk detection overview')}
                </h2>
                <p className='text-muted-foreground mt-2 max-w-2xl text-sm leading-6'>
                  {t(
                    'Live detection totals are shown only when the security overview service is available.'
                  )}
                </p>
              </div>
              {overview?.period_label && (
                <Badge variant='outline'>{overview.period_label}</Badge>
              )}
            </div>
            <MetricsPanel
              overview={overview}
              isLoading={securityQuery.isLoading}
            />
          </section>

          <div className='grid gap-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(20rem,0.9fr)]'>
            <section
              aria-labelledby='security-rules-title'
              className='space-y-5'
            >
              <div>
                <h2
                  id='security-rules-title'
                  className='font-serif text-3xl font-normal tracking-tight'
                >
                  {t('Safety rules')}
                </h2>
                <p className='text-muted-foreground mt-2 text-sm leading-6'>
                  {t(
                    'The rules below are a public summary. The active server policy and applicable law take precedence.'
                  )}
                </p>
              </div>
              <div className='grid gap-3 sm:grid-cols-2'>
                {PUBLIC_RULES.map((rule) => {
                  const Icon = rule.icon
                  return (
                    <Card key={rule.title} size='sm'>
                      <CardHeader>
                        <div className='flex items-start gap-3'>
                          <Icon className='text-muted-foreground mt-0.5 size-5 shrink-0' />
                          <CardTitle>{t(rule.title)}</CardTitle>
                        </div>
                      </CardHeader>
                      <CardContent className='text-muted-foreground leading-6'>
                        {t(rule.description)}
                      </CardContent>
                    </Card>
                  )
                })}
              </div>
            </section>

            <section
              aria-labelledby='security-charges-title'
              className='space-y-5'
            >
              <div>
                <h2
                  id='security-charges-title'
                  className='font-serif text-3xl font-normal tracking-tight'
                >
                  {t('Violation charges')}
                </h2>
                <p className='text-muted-foreground mt-2 text-sm leading-6'>
                  {t(
                    'Only charges returned by the live server policy are shown. If no schedule is published, this page intentionally shows no amount.'
                  )}
                </p>
              </div>
              <ChargeSchedule charges={overview?.violation_charges} />
            </section>
          </div>

          <section
            aria-labelledby='security-enforcement-title'
            className='space-y-5'
          >
            <div>
              <h2
                id='security-enforcement-title'
                className='font-serif text-3xl font-normal tracking-tight'
              >
                {t('Detection and response')}
              </h2>
            </div>
            <div className='grid gap-3 md:grid-cols-3'>
              {DETECTION_PRINCIPLES.map((principle) => {
                const Icon = principle.icon
                return (
                  <Card key={principle.title} size='sm'>
                    <CardHeader>
                      <Icon className='text-muted-foreground mb-2 size-5' />
                      <CardTitle>{t(principle.title)}</CardTitle>
                    </CardHeader>
                    <CardContent className='text-muted-foreground leading-6'>
                      {t(principle.description)}
                    </CardContent>
                  </Card>
                )
              })}
            </div>
          </section>

          {!hasLivePolicy && (
            <section aria-labelledby='security-status-title'>
              <UnavailableState
                title={t(
                  'The public security overview API is not available yet.'
                )}
                description={t(
                  'Statistics and charge amounts will appear here after the server publishes the public security policy. Current endpoint:'
                )}
                icon={AlertTriangle}
              />
              <p className='text-muted-foreground mt-3 text-xs'>
                <span id='security-status-title' className='font-medium'>
                  {t('Endpoint')}
                </span>{' '}
                <code className='font-mono'>{SECURITY_OVERVIEW_ENDPOINT}</code>
              </p>
            </section>
          )}

          {overview?.generated_at && (
            <p className='text-muted-foreground text-xs'>
              {t('Last updated:')}{' '}
              {new Date(overview.generated_at).toLocaleString()}
            </p>
          )}
        </div>
      </main>
    </ForgePublicShell>
  )
}
