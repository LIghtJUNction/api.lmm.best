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
  AlertCircle,
  CircleCheck,
  CircleHelp,
  CircleX,
  RefreshCw,
  TriangleAlert,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { PublicLayout } from '@/components/layout'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
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
import { sortStatusGroups } from './lib/aggregate'
import type { StatusGroup, StatusSort } from './types'

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

function SummaryMetric(props: {
  label: string
  value: string
  detail?: string
}) {
  return (
    <div className='flex min-w-0 items-baseline gap-2'>
      <dt className='text-muted-foreground shrink-0 text-xs'>{props.label}</dt>
      <dd className='text-foreground min-w-0 truncate font-mono text-sm font-semibold tabular-nums'>
        {props.value}
      </dd>
      {props.detail && (
        <span className='text-muted-foreground min-w-0 truncate text-xs'>
          {props.detail}
        </span>
      )}
    </div>
  )
}

function TtftTrend(props: { values: number[]; label: string }) {
  const values = props.values.filter(
    (value) => Number.isFinite(value) && value > 0
  )
  if (values.length === 0) {
    return (
      <div className='border-border/50 text-muted-foreground flex h-16 items-center justify-center rounded-md border border-dashed text-xs'>
        {props.label}
      </div>
    )
  }

  const max = Math.max(...values)
  return (
    <div className='flex flex-col gap-1.5'>
      <div className='text-muted-foreground flex items-center justify-between gap-3 text-[11px]'>
        <span>{props.label}</span>
        <span>{formatLatency(values.at(-1) ?? Number.NaN)}</span>
      </div>
      <div
        className='border-border/50 bg-muted/10 flex h-14 items-end gap-0.5 rounded-md border px-2 py-2'
        role='img'
        aria-label={props.label}
      >
        {values.map((value, index) => (
          <span
            key={`${index}-${value}`}
            title={formatLatency(value)}
            className='bg-primary/55 hover:bg-primary min-w-0 flex-1 rounded-[2px] transition-colors'
            style={{ height: `${Math.max(12, (value / max) * 100)}%` }}
            aria-hidden='true'
          />
        ))}
      </div>
    </div>
  )
}

function SuccessPips(props: { values: number[]; label: string }) {
  const values = props.values.filter(Number.isFinite).slice(-12)
  if (values.length === 0) return null

  return (
    <div
      className='flex items-center gap-1'
      role='img'
      aria-label={props.label}
    >
      {values.map((value, index) => (
        <span
          key={`${index}-${value}`}
          title={formatUptimePct(value)}
          className={cn('size-1.5 rounded-full', getSuccessRateDotClass(value))}
          aria-hidden='true'
        />
      ))}
    </div>
  )
}

function GroupStatusCard(props: {
  group: StatusGroup
  ttftTrendLabel: string
  successTrendLabel: string
}) {
  const { t } = useTranslation()
  const level = getSuccessRateLevel(props.group.successRate)
  const Icon = statusIcon(level)

  return (
    <Card className='border-border/70 bg-card min-w-0 shadow-none' size='sm'>
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
        <div className='flex items-center justify-between gap-3'>
          <span className='text-muted-foreground text-[11px]'>
            {t('{{count}} models reporting', { count: props.group.modelCount })}
          </span>
          <SuccessPips
            values={props.group.successTrend}
            label={props.successTrendLabel}
          />
        </div>
      </CardHeader>
      <CardContent className='flex flex-col gap-3 px-4 py-3'>
        <dl>
          <div className='flex items-baseline justify-between gap-3'>
            <dt className='text-muted-foreground text-xs font-medium'>
              {t('Average TTFT')}
            </dt>
            <dd className='text-foreground font-mono text-xl font-semibold tabular-nums'>
              {formatLatency(props.group.avgTtftMs)}
            </dd>
          </div>
        </dl>
        <TtftTrend
          values={props.group.ttftTrend}
          label={props.ttftTrendLabel}
        />
        <dl className='border-border/60 grid grid-cols-2 border-t pt-3'>
          <MetricValue
            label={t('Average latency')}
            value={formatLatency(props.group.avgLatencyMs)}
          />
          <MetricValue
            label={t('Throughput')}
            value={formatThroughput(props.group.avgTps)}
          />
        </dl>
      </CardContent>
    </Card>
  )
}

function MetricValue(props: { label: string; value: string }) {
  return (
    <div className='min-w-0 first:pr-3 last:border-l last:pl-3'>
      <dt className='text-muted-foreground truncate text-[11px]'>
        {props.label}
      </dt>
      <dd className='text-foreground mt-0.5 truncate font-mono text-sm font-semibold tabular-nums'>
        {props.value}
      </dd>
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
  const [sort, setSort] = useState<StatusSort>('ttft')
  const sortedGroups = useMemo(
    () => sortStatusGroups(status.groups, sort),
    [sort, status.groups]
  )
  const fastestGroup = useMemo(
    () => sortStatusGroups(status.groups, 'ttft')[0],
    [status.groups]
  )
  const healthyCount = status.groups.filter((group) =>
    ['excellent', 'good'].includes(getSuccessRateLevel(group.successRate))
  ).length
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
              <h1 className='text-foreground text-2xl font-semibold tracking-tight sm:text-3xl'>
                {t('Status detection')}
              </h1>
              <p className='text-muted-foreground mt-1 text-sm'>
                {t('Last 24 hours')}
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
                data-icon='inline-start'
                className={cn(status.isFetching && 'animate-spin')}
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
              <dl className='border-border/70 bg-card flex flex-wrap items-center gap-x-6 gap-y-2 rounded-lg border px-4 py-3'>
                <SummaryMetric
                  label={t('Fastest first token')}
                  value={
                    fastestGroup &&
                    Number.isFinite(fastestGroup.avgTtftMs) &&
                    fastestGroup.avgTtftMs > 0
                      ? formatLatency(fastestGroup.avgTtftMs)
                      : '—'
                  }
                  detail={
                    fastestGroup &&
                    Number.isFinite(fastestGroup.avgTtftMs) &&
                    fastestGroup.avgTtftMs > 0
                      ? fastestGroup.group
                      : undefined
                  }
                />
                <SummaryMetric
                  label={t('Groups monitored')}
                  value={String(status.groups.length)}
                />
                <SummaryMetric
                  label={t('Operational')}
                  value={String(healthyCount)}
                />
                <SummaryMetric
                  label={t('Models checked')}
                  value={String(status.modelsWithData)}
                />
              </dl>

              {status.failedModelCount > 0 && (
                <p className='text-muted-foreground text-xs'>
                  {t('{{count}} model checks could not be completed.', {
                    count: status.failedModelCount,
                  })}
                </p>
              )}

              <section aria-labelledby='status-groups-heading'>
                <div className='mb-3 flex flex-wrap items-end justify-between gap-3'>
                  <div>
                    <h2
                      id='status-groups-heading'
                      className='text-foreground text-base font-semibold tracking-tight'
                    >
                      {t('Group status')}
                    </h2>
                    <p className='text-muted-foreground mt-0.5 text-xs'>
                      {t('{{count}} groups', { count: status.groups.length })}
                    </p>
                  </div>
                  <Select
                    value={sort}
                    onValueChange={(value) =>
                      value !== null && setSort(value as StatusSort)
                    }
                  >
                    <SelectTrigger
                      size='sm'
                      className='w-full sm:w-48'
                      aria-label={t('Sort groups')}
                    >
                      <SelectValue>
                        {sort === 'ttft'
                          ? t('Fastest first token')
                          : sort === 'reliability'
                            ? t('Highest success rate')
                            : t('Group name')}
                      </SelectValue>
                    </SelectTrigger>
                    <SelectContent alignItemWithTrigger={false}>
                      <SelectGroup>
                        <SelectItem value='ttft'>
                          {t('Fastest first token')}
                        </SelectItem>
                        <SelectItem value='reliability'>
                          {t('Highest success rate')}
                        </SelectItem>
                        <SelectItem value='name'>{t('Group name')}</SelectItem>
                      </SelectGroup>
                    </SelectContent>
                  </Select>
                </div>
                <div className='grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3'>
                  {sortedGroups.map((group) => (
                    <GroupStatusCard
                      key={group.group}
                      group={group}
                      ttftTrendLabel={t('First-token trend')}
                      successTrendLabel={t('Success rate trend')}
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
