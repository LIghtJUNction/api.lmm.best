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
import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { ArrowRight, CircleDollarSign, Sparkles, Tag } from 'lucide-react'
import { type ReactNode, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { Badge } from '@/components/ui/badge'
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
import { getPublicPlans } from '@/features/subscriptions/api'
import { formatDuration, formatResetPeriod } from '@/features/subscriptions/lib'
import { getTopupInfo } from '@/features/wallet/api'
import { formatCreditBalance } from '@/features/wallet/lib/format'
import { getCurrencyDisplay } from '@/lib/currency'

import {
  compareAssistantPlans,
  getAssistantTopupOffers,
} from './plan-recommender'

function formatPlanPrice(amount: number, currency: string, locale: string) {
  try {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency: currency || 'USD',
      maximumFractionDigits: 2,
    }).format(amount)
  } catch {
    return `${amount.toFixed(2)} ${currency}`
  }
}

export function AssistantPlanTool(props: { developerAccessGranted: boolean }) {
  const { t, i18n } = useTranslation()
  const [expectedCredit, setExpectedCredit] = useState('20')
  const plansQuery = useQuery({
    queryKey: ['subscription-plans'],
    queryFn: getPublicPlans,
    enabled: props.developerAccessGranted,
    staleTime: 5 * 60 * 1000,
    retry: false,
  })
  const topupQuery = useQuery({
    queryKey: ['topup-info'],
    queryFn: getTopupInfo,
    staleTime: 5 * 60 * 1000,
    retry: false,
  })
  const expected = Number(expectedCredit)
  const quotaPerUnit = getCurrencyDisplay().config.quotaPerUnit
  const comparisons = useMemo(
    () =>
      compareAssistantPlans(
        plansQuery.data?.data ?? [],
        expected,
        quotaPerUnit
      ),
    [expected, plansQuery.data?.data, quotaPerUnit]
  )
  const offers = useMemo(
    () => getAssistantTopupOffers(topupQuery.data?.data?.discount),
    [topupQuery.data?.data?.discount]
  )

  const loading =
    topupQuery.isLoading ||
    (props.developerAccessGranted && plansQuery.isLoading)
  const noPlans =
    props.developerAccessGranted && !loading && comparisons.length === 0
  let planContent: ReactNode = (
    <div className='grid gap-2'>
      {comparisons.slice(0, 3).map((comparison) => {
        const plan = comparison.record.plan
        return (
          <div
            key={plan.id}
            className={
              comparison.recommended
                ? 'border-primary/70 bg-primary/5 grid gap-2 rounded-lg border p-3'
                : 'grid gap-2 rounded-lg border p-3'
            }
          >
            <div className='flex items-start justify-between gap-3'>
              <div className='min-w-0'>
                <p className='truncate text-sm font-medium'>{plan.title}</p>
                <p className='text-muted-foreground text-xs'>
                  {formatDuration(plan, t)} · {formatResetPeriod(plan, t)}
                </p>
              </div>
              {comparison.recommended ? (
                <Badge className='shrink-0' variant='secondary'>
                  <Sparkles aria-hidden='true' />
                  {t('Closest fit')}
                </Badge>
              ) : null}
            </div>
            <div className='flex flex-wrap items-center justify-between gap-2 text-xs'>
              <span className='text-muted-foreground'>
                {t('Estimated monthly capacity')}:{' '}
                <strong className='text-foreground'>
                  {comparison.monthlyCreditUSD === null
                    ? t('Unlimited')
                    : formatCreditBalance(comparison.monthlyCreditUSD)}
                </strong>
              </span>
              <strong>
                {formatPlanPrice(
                  Number(plan.price_amount || 0),
                  plan.currency,
                  i18n.language
                )}
              </strong>
            </div>
          </div>
        )
      })}
    </div>
  )
  if (!props.developerAccessGranted) {
    planContent = (
      <div className='bg-muted/40 rounded-lg border p-3 text-xs leading-5'>
        {t(
          'Top-up discounts remain available while L0 access is under review. Live subscription comparison unlocks after L1 approval.'
        )}
      </div>
    )
  } else if (loading) {
    planContent = (
      <p className='text-muted-foreground text-sm'>{t('Loading...')}</p>
    )
  } else if (noPlans) {
    planContent = (
      <p className='text-muted-foreground text-sm'>
        {t('No subscription plans are currently available.')}
      </p>
    )
  }

  return (
    <Card size='sm'>
      <CardHeader>
        <CardTitle className='flex items-center gap-2'>
          <CircleDollarSign className='size-4' aria-hidden='true' />
          {t('Live plan and discount advisor')}
        </CardTitle>
        <CardDescription>
          {t(
            'Enter the API credit you expect to use each month. Recommendations use current plan quotas, not marketing labels.'
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className='grid gap-4'>
        {props.developerAccessGranted ? (
          <div className='grid gap-1.5'>
            <Label htmlFor='assistant-expected-credit'>
              {t('Expected monthly API credit (USD)')}
            </Label>
            <Input
              id='assistant-expected-credit'
              type='number'
              inputMode='decimal'
              min={0}
              step={5}
              value={expectedCredit}
              onChange={(event) => setExpectedCredit(event.target.value)}
            />
          </div>
        ) : null}

        {planContent}

        {offers.length > 0 ? (
          <div className='bg-muted/40 grid gap-2 rounded-lg border p-3'>
            <div className='flex items-center gap-2 text-sm font-medium'>
              <Tag className='size-4' aria-hidden='true' />
              {t('Best current top-up discounts')}
            </div>
            <div className='flex flex-wrap gap-2'>
              {offers.slice(0, 3).map((offer) => (
                <Badge key={offer.amount} variant='outline'>
                  {formatCreditBalance(offer.amount)} ·{' '}
                  {t('save {{percent}}%', {
                    percent: new Intl.NumberFormat(i18n.language, {
                      maximumFractionDigits: 1,
                    }).format(offer.savingsPercent),
                  })}
                </Badge>
              ))}
            </div>
          </div>
        ) : null}

        <p className='text-muted-foreground text-xs leading-5'>
          {t(
            'Plan fit compares included credit only. Reset rules, model access, payment method, and group multipliers may change the final value; checkout remains authoritative.'
          )}
        </p>
        <Button variant='outline' render={<Link to='/wallet' />}>
          {props.developerAccessGranted
            ? t('Review plans and exact checkout prices')
            : t('Add funds')}
          <ArrowRight data-icon='inline-end' aria-hidden='true' />
        </Button>
      </CardContent>
    </Card>
  )
}
