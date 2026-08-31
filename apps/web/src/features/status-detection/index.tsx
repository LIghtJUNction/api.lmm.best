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
  Activity,
  AlertCircle,
  CircleCheck,
  CircleHelp,
  CircleX,
  Gauge,
  HeartPulse,
  RefreshCw,
  Timer,
  TriangleAlert,
} from 'lucide-react'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'

import { PublicLayout } from '@/components/layout'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import {
  formatLatency,
  formatThroughput,
  formatUptimePct,
  getSuccessRateDotClass,
  getSuccessRateLevel,
  getSuccessRateTextClass,
  type SuccessRateLevel,
} from '@/features/performance-metrics/lib/format'
import { cn } from '@/lib/utils'

import { useStatusDetection } from './hooks/use-status-detection'
import type { StatusGroup } from './types'

function statusLabel(t: (key: string) => string, level: SuccessRateLevel) {
  switch (level) {
    case 'excellent':
      return t('Operational')
    case 'good':
      return t('Operational')
    case 'warning':
      return t('Degraded')
    case 'critical':
      return t('Outage')
    default:
      return t('No data')
  }
}

function statusIcon(level: SuccessRateLevel) {
  switch (level) {
    case 'excellent':
    case 'good':
      return CircleCheck
    case 'warning':
      return TriangleAlert
    case 'critical':
      return CircleX
    default:
      return CircleHelp
  }
}

function statusSurface(level: SuccessRateLevel) {
  switch (level) {
    case 'excellent':
    case 'good':
      return 'border-emerald-500/25 bg-emerald-500/5'
    case 'warning':
      return 'border-amber-500/25 bg-amber-500/5'
    case 'critical':
      return 'border-red-500/25 bg-red-500/5'
    default:
      return 'border-border/60 bg-muted/15'
  }
}

function OverviewMetric(props: {
  icon: React.ComponentType<{ className?: string }>
  label: string
  value: string
  hint: string
}) {
  const Icon = props.icon
  return (
    <div className='border-border/70 bg-card rounded-xl border px-4 py-3 sm:px-5 sm:py-4'>
      <div className='text-muted-foreground flex items-center gap-2 text-xs font-medium'>
        <Icon className='size-3.5' aria-hidden='true' />
        <span>{props.label}</span>
      </div>
      <div className='text-foreground mt-2 font-mono text-xl font-semibold tabular-nums sm:text-2xl'>
        {props.value}
      </div>
      <div className='text-muted-foreground/75 mt-1 text-[11px]'>
        {props.hint}
      </div>
    </div>
  )
}

function StatusTrend(props: { values: number[]; label: string }) {
  if (props.values.length === 0) {
    return (
      <div className='border-border/50 bg-muted/10 text-muted-foreground/70 flex h-16 items-center justify-center rounded-md border border-dashed text-xs'>
        {props.label}
      </div>
    )
  }

  return (
    <div
      className='border-border/50 bg-muted/10 flex h-16 items-end gap-0.5 rounded-md border px-2 py-2'
      aria-label={props.label}
    >
      {props.values.map((value, index) => {
        const safeValue = Number.isFinite(value)
          ? Math.max(0, Math.min(100, value))
          : 0
        return (
          <span
            key={`${index}-${value}`}
            title={`${formatUptimePct(safeValue)} ${props.label}`}
            className={cn(
              'min-w-0 flex-1 rounded-[2px]',
              getSuccessRateDotClass(value)
            )}
            style={{ height: `${Math.max(8, safeValue)}%` }}
          />
        )
      })}
    </div>
  )
}

function GroupStatusCard(props: { group: StatusGroup; trendLabel: string }) {
  const { t } = useTranslation()
  const level = getSuccessRateLevel(props.group.successRate)
  const Icon = statusIcon(level)

  return (
    <Card className={cn('min-w-0 shadow-xs', statusSurface(level))} size='sm'>
      <CardHeader className='border-border/60 gap-2 border-b px-4 py-3'>
        <div className='flex min-w-0 items-start justify-between gap-3'>
          <CardTitle className='min-w-0 truncate text-base font-semibold tracking-tight'>
            {props.group.group}
          </CardTitle>
          <div
            className={cn(
              'flex shrink-0 items-center gap-1.5 text-xs font-semibold',
              getSuccessRateTextClass(props.group.successRate)
            )}
          >
            <Icon className='size-3.5' aria-hidden='true' />
            <span>{statusLabel(t, level)}</span>
            <span className='font-mono tabular-nums'>
              {formatUptimePct(props.group.successRate)}
            </span>
          </div>
        </div>
        <div className='text-muted-foreground flex items-center gap-1.5 text-[11px]'>
          <Activity className='size-3' aria-hidden='true' />
          {t('{{count}} models reporting', { count: props.group.modelCount })}
        </div>
      </CardHeader>
      <CardContent className='space-y-3 px-4 py-3'>
        <StatusTrend values={props.group.trend} label={props.trendLabel} />
        <div className='grid grid-cols-3 gap-2'>
          <MetricValue
            icon={Timer}
            label={t('Average latency')}
            value={formatLatency(props.group.avgLatencyMs)}
          />
          <MetricValue
            icon={Gauge}
            label={t('Throughput')}
            value={formatThroughput(props.group.avgTps)}
          />
          <MetricValue
            icon={HeartPulse}
            label={t('Status')}
            value={statusLabel(t, level)}
            valueClassName={getSuccessRateTextClass(props.group.successRate)}
          />
        </div>
      </CardContent>
    </Card>
  )
}

function MetricValue(props: {
  icon: React.ComponentType<{ className?: string }>
  label: string
  value: string
  valueClassName?: string
}) {
  const Icon = props.icon
  return (
    <div className='border-border/50 bg-background/45 min-w-0 rounded-md border px-2.5 py-2'>
      <div className='text-muted-foreground flex items-center gap-1 text-[10px] font-medium'>
        <Icon className='size-3 shrink-0' aria-hidden='true' />
        <span className='truncate'>{props.label}</span>
      </div>
      <div
        className={cn(
          'text-foreground mt-1 truncate font-mono text-sm font-semibold tabular-nums',
          props.valueClassName
        )}
      >
        {props.value}
      </div>
    </div>
  )
}

function StatusDetectionSkeleton() {
  return (
    <div className='space-y-4'>
      <div className='grid grid-cols-2 gap-2 sm:grid-cols-4'>
        {Array.from({ length: 4 }).map((_, index) => (
          <Skeleton key={index} className='h-24 rounded-xl' />
        ))}
      </div>
      <div className='grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3'>
        {Array.from({ length: 6 }).map((_, index) => (
          <Skeleton key={index} className='h-52 rounded-xl' />
        ))}
      </div>
    </div>
  )
}

function EmptyStatusState(props: { message: string }) {
  return (
    <div className='border-border/70 bg-card rounded-xl border border-dashed px-6 py-14 text-center'>
      <AlertCircle
        className='text-muted-foreground/60 mx-auto size-8'
        aria-hidden='true'
      />
      <p className='text-foreground mt-3 text-sm font-semibold'>
        {props.message}
      </p>
    </div>
  )
}

export function StatusDetection() {
  const { t } = useTranslation()
  const status = useStatusDetection()
  const healthyCount = useMemo(
    () =>
      status.groups.filter((group) =>
        ['excellent', 'good'].includes(getSuccessRateLevel(group.successRate))
      ).length,
    [status.groups]
  )
  const attentionCount = useMemo(
    () =>
      status.groups.filter((group) =>
        ['warning', 'critical'].includes(getSuccessRateLevel(group.successRate))
      ).length,
    [status.groups]
  )
  const hasError = Boolean(status.error)

  return (
    <PublicLayout
      showMainContainer={false}
      headerProps={{ className: 'forge-public-header' }}
    >
      <main className='min-h-svh pt-16'>
        <div className='mx-auto w-full max-w-[1280px] space-y-5 px-3 pt-8 pb-14 sm:px-6 sm:pt-12 xl:px-8'>
          <div className='flex flex-wrap items-end justify-between gap-3'>
            <div className='min-w-0'>
              <p className='text-muted-foreground mb-1 text-xs font-medium tracking-[0.14em] uppercase'>
                {t('Service observability')}
              </p>
              <h1 className='text-foreground text-2xl font-semibold tracking-tight sm:text-3xl'>
                {t('Status detection')}
              </h1>
              <p className='text-muted-foreground mt-1.5 max-w-2xl text-sm'>
                {t(
                  'Check recent availability and performance for each model group.'
                )}
              </p>
            </div>
            <Button
              variant='outline'
              size='sm'
              onClick={() => void status.refresh()}
              disabled={status.isFetching}
              aria-label={t('Refresh')}
            >
              <RefreshCw
                className={cn('size-3.5', status.isFetching && 'animate-spin')}
                aria-hidden='true'
              />
              {t('Refresh')}
            </Button>
          </div>

          {hasError && (
            <Alert variant='destructive'>
              <AlertCircle />
              <AlertTitle>{t('Unable to load status data')}</AlertTitle>
              <AlertDescription className='flex flex-wrap items-center gap-2'>
                <span>{t('Please try again in a moment.')}</span>
                <Button
                  variant='outline'
                  size='xs'
                  onClick={() => void status.refresh()}
                >
                  {t('Retry')}
                </Button>
              </AlertDescription>
            </Alert>
          )}

          {status.isLoading ? (
            <StatusDetectionSkeleton />
          ) : hasError ? null : status.groups.length === 0 ? (
            <EmptyStatusState message={t('No status data is available yet.')} />
          ) : (
            <>
              <div className='grid grid-cols-2 gap-2 sm:grid-cols-4 sm:gap-3'>
                <OverviewMetric
                  icon={Activity}
                  label={t('Groups monitored')}
                  value={String(status.groups.length)}
                  hint={t('Active groups with recent traffic')}
                />
                <OverviewMetric
                  icon={HeartPulse}
                  label={t('Operational')}
                  value={String(healthyCount)}
                  hint={t('Groups at 90% success or higher')}
                />
                <OverviewMetric
                  icon={TriangleAlert}
                  label={t('Groups needing attention')}
                  value={String(attentionCount)}
                  hint={t('Groups needing attention')}
                />
                <OverviewMetric
                  icon={Gauge}
                  label={t('Models checked')}
                  value={String(status.modelsWithData)}
                  hint={t('Top models by recent traffic')}
                />
              </div>

              {status.failedModelCount > 0 && (
                <p className='text-muted-foreground text-xs'>
                  {t('{{count}} model checks could not be completed.', {
                    count: status.failedModelCount,
                  })}
                </p>
              )}

              <section aria-labelledby='status-groups-heading'>
                <div className='mb-3 flex items-center justify-between gap-3'>
                  <div>
                    <h2
                      id='status-groups-heading'
                      className='text-foreground text-base font-semibold tracking-tight'
                    >
                      {t('Group status')}
                    </h2>
                    <p className='text-muted-foreground mt-0.5 text-xs'>
                      {t('Last 24 hours')}
                    </p>
                  </div>
                  <span className='text-muted-foreground text-xs tabular-nums'>
                    {t('{{count}} groups', { count: status.groups.length })}
                  </span>
                </div>
                <div className='grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3'>
                  {status.groups.map((group) => (
                    <GroupStatusCard
                      key={group.group}
                      group={group}
                      trendLabel={t('Success rate trend')}
                    />
                  ))}
                </div>
              </section>
            </>
          )}
        </div>
      </main>
    </PublicLayout>
  )
}
