/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
*/
import { useQuery } from '@tanstack/react-query'
import { RotateCcw } from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { ConfirmDialog } from '@/components/confirm-dialog'
import { StatusBadge } from '@/components/status-badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import {
  getSubscriptionResetVouchers,
  redeemSubscriptionResetVoucher,
} from '@/features/subscriptions/api'
import { formatTimestamp } from '@/features/subscriptions/lib'
import type { SubscriptionResetVoucher } from '@/features/subscriptions/types'
import { formatQuota } from '@/lib/format'

export function SubscriptionResetVouchers(props: { onRedeemed?: () => void }) {
  const { t } = useTranslation()
  const [selected, setSelected] = useState<SubscriptionResetVoucher | null>(
    null
  )
  const [redeemedVoucherIds, setRedeemedVoucherIds] = useState<Set<number>>(
    () => new Set()
  )
  const [redeeming, setRedeeming] = useState(false)
  const vouchersQuery = useQuery({
    queryKey: ['subscription-reset-vouchers'],
    queryFn: getSubscriptionResetVouchers,
    staleTime: 15_000,
  })
  const vouchers = vouchersQuery.data?.data ?? []

  const redeem = async () => {
    if (!selected) return
    setRedeeming(true)
    try {
      const response = await redeemSubscriptionResetVoucher(selected.id)
      if (!response.success || !response.data) {
        throw new Error(response.message || t('Voucher redemption failed'))
      }
      toast.success(
        t('Reset {{count}} subscriptions and restored {{quota}}.', {
          count: response.data.reset_count,
          quota: formatQuota(response.data.restored_quota),
        })
      )
      setRedeemedVoucherIds((current) => {
        const next = new Set(current)
        next.add(selected.id)
        return next
      })
      setSelected(null)
      props.onRedeemed?.()
      void vouchersQuery.refetch()
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : t('Voucher redemption failed')
      )
    } finally {
      setRedeeming(false)
    }
  }

  return (
    <section
      className='rounded-none border p-3 sm:p-4'
      aria-labelledby='banked-reset-heading'
    >
      <div className='flex items-center justify-between gap-3'>
        <div>
          <h3 id='banked-reset-heading' className='text-sm font-medium'>
            {t('Banked subscription resets')}
          </h3>
          <p className='text-muted-foreground mt-0.5 text-xs'>
            {t(
              'A voucher resets used quota without changing subscription expiry or schedule.'
            )}
          </p>
        </div>
        <Button
          variant='ghost'
          size='sm'
          disabled={vouchersQuery.isFetching}
          onClick={() => void vouchersQuery.refetch()}
        >
          {t('Refresh')}
        </Button>
      </div>

      {vouchersQuery.isPending ? (
        <div className='mt-3 space-y-2'>
          <Skeleton className='h-14 w-full' />
          <Skeleton className='h-14 w-full' />
        </div>
      ) : vouchersQuery.isError ? (
        <div className='mt-3 rounded-md border border-dashed p-3 text-sm'>
          <p className='font-medium'>{t('Failed to load banked resets')}</p>
          <Button
            variant='outline'
            size='sm'
            className='mt-2'
            onClick={() => void vouchersQuery.refetch()}
          >
            {t('Retry')}
          </Button>
        </div>
      ) : vouchers.length === 0 ? (
        <p className='text-muted-foreground mt-3 text-sm'>
          {t('No banked reset vouchers')}
        </p>
      ) : (
        <div className='mt-3 space-y-2'>
          {vouchers.map((voucher) => {
            const status = redeemedVoucherIds.has(voucher.id)
              ? 'redeemed'
              : voucher.status === 'available' &&
                  (voucher.expired === true ||
                    voucher.expires_at <= Date.now() / 1000)
                ? 'expired'
                : voucher.status
            return (
              <div
                key={voucher.id}
                className='flex flex-wrap items-center justify-between gap-3 rounded-md border p-3'
              >
                <div className='min-w-0'>
                  <div className='flex flex-wrap items-center gap-2'>
                    <span className='text-sm font-medium'>
                      {voucher.plan_title || `#${voucher.plan_id}`}
                    </span>
                    <StatusBadge
                      label={t(
                        status === 'available'
                          ? 'Available'
                          : status === 'redeemed'
                            ? 'Redeemed'
                            : 'Expired'
                      )}
                      variant={status === 'available' ? 'success' : 'neutral'}
                      copyable={false}
                    />
                  </div>
                  <p className='text-muted-foreground mt-1 text-xs'>
                    {status === 'redeemed'
                      ? t('Redeemed at {{time}}', {
                          time: formatTimestamp(voucher.redeemed_at),
                        })
                      : t('Expires at {{time}}', {
                          time: formatTimestamp(voucher.expires_at),
                        })}
                  </p>
                </div>
                {status === 'available' && (
                  <Button
                    size='sm'
                    variant='outline'
                    onClick={() => setSelected(voucher)}
                  >
                    <RotateCcw aria-hidden='true' />
                    {t('Redeem reset')}
                  </Button>
                )}
              </div>
            )
          })}
        </div>
      )}

      {selected && (
        <ConfirmDialog
          open
          onOpenChange={(open) => !open && setSelected(null)}
          title={t('Redeem banked subscription reset')}
          desc={t(
            'Reset used quota for all current active subscriptions on {{plan}}? Expiry and reset schedule will not change.',
            { plan: selected.plan_title || `#${selected.plan_id}` }
          )}
          confirmText={t('Redeem reset')}
          isLoading={redeeming}
          handleConfirm={() => void redeem()}
        />
      )}
    </section>
  )
}
