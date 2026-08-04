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
import {
  ExternalLinkIcon,
  GiftIcon,
  Invoice01Icon,
  Loading03Icon,
  WalletCardsIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'

import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader } from '@/components/ui/card'
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
} from '@/components/ui/field'
import { IconBadge } from '@/components/ui/icon-badge'
import { Input } from '@/components/ui/input'
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from '@/components/ui/input-group'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'
import { Skeleton } from '@/components/ui/skeleton'
import { TitledCard } from '@/components/ui/titled-card'
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from '@/components/ui/tooltip'
import { usesDedicatedPaymentPricing } from '@/lib/payment-pricing'
import { cn } from '@/lib/utils'

import {
  getPaymentIcon,
  getPaymentTopupRatio,
  getDefaultPaymentType,
  getMinTopupAmount,
  calculatePresetPricing,
  formatCreditBalance,
  formatCreditValue,
  formatPaymentAmount,
  formatPaymentSettlementRate,
  formatSettlementAmount,
  getPaymentSettlementUnit,
  isWaffoPancakeCurrencySupported,
} from '../lib'
import type {
  PaymentMethod,
  PresetAmount,
  TopupInfo,
  CreemProduct,
  WaffoPayMethod,
} from '../types'
import { CreemProductsSection } from './creem-products-section'

interface RechargeFormCardProps {
  topupInfo: TopupInfo | null
  presetAmounts: PresetAmount[]
  selectedPreset: number | null
  onSelectPreset: (preset: PresetAmount) => void
  topupAmount: number
  onTopupAmountChange: (amount: number) => void
  paymentAmount: number
  selectedPaymentMethod?: PaymentMethod
  calculating: boolean
  onPaymentMethodSelect: (method: PaymentMethod) => void
  paymentLoading: string | null
  redemptionCode: string
  onRedemptionCodeChange: (code: string) => void
  onRedeem: () => void
  redeeming: boolean
  topupLink?: string
  loading?: boolean
  priceRatio?: number
  onOpenBilling?: () => void
  creemProducts?: CreemProduct[]
  enableCreemTopup?: boolean
  onCreemProductSelect?: (product: CreemProduct) => void
  enableWaffoTopup?: boolean
  waffoPayMethods?: WaffoPayMethod[]
  waffoMinTopup?: number
  onWaffoMethodSelect?: (method: WaffoPayMethod, index: number) => void
  enableWaffoPancakeTopup?: boolean
}

export function RechargeFormCard({
  topupInfo,
  presetAmounts,
  selectedPreset,
  onSelectPreset,
  topupAmount,
  onTopupAmountChange,
  paymentAmount,
  selectedPaymentMethod,
  calculating,
  onPaymentMethodSelect,
  paymentLoading,
  redemptionCode,
  onRedemptionCodeChange,
  onRedeem,
  redeeming,
  topupLink,
  loading,
  priceRatio = 1,
  onOpenBilling,
  creemProducts,
  enableCreemTopup,
  onCreemProductSelect,
  enableWaffoTopup,
  waffoPayMethods,
  waffoMinTopup,
  onWaffoMethodSelect,
  enableWaffoPancakeTopup,
}: RechargeFormCardProps) {
  const { t } = useTranslation()
  const [localAmount, setLocalAmount] = useState(topupAmount.toString())

  useEffect(() => {
    // Empty string must survive, otherwise the field can never be cleared
    setLocalAmount((prev) =>
      prev === '' && topupAmount === 0 ? prev : topupAmount.toString()
    )
  }, [topupAmount])

  const handleAmountChange = (value: string) => {
    setLocalAmount(value)
    const numValue = Number.parseInt(value) || 0
    if (numValue >= 0) {
      onTopupAmountChange(numValue)
    }
  }

  const hasConfigurableTopup =
    topupInfo?.enable_online_topup ||
    topupInfo?.enable_stripe_topup ||
    enableWaffoTopup ||
    enableWaffoPancakeTopup
  const hasAnyTopup = hasConfigurableTopup || enableCreemTopup
  const hasStandardPaymentMethods =
    Array.isArray(topupInfo?.pay_methods) && topupInfo.pay_methods.length > 0
  const hasWaffoPaymentMethods =
    Array.isArray(waffoPayMethods) && waffoPayMethods.length > 0
  const minTopup = getMinTopupAmount(topupInfo)
  const topupGroupRatio = topupInfo?.topup_group_ratio ?? 1
  const redemptionEnabled = topupInfo?.enable_redemption !== false
  const customDiscount = topupInfo?.discount?.[topupAmount] || 1
  const customHasDiscount = customDiscount > 0 && customDiscount < 1
  const customOriginalPayment = customHasDiscount
    ? paymentAmount / customDiscount
    : paymentAmount
  const customDiscountAmount = customOriginalPayment - paymentAmount
  const defaultPaymentType = getDefaultPaymentType(topupInfo)
  const effectivePaymentMethod =
    selectedPaymentMethod ??
    topupInfo?.pay_methods?.find((method) => method.type === defaultPaymentType)
  const settlementUnit = getPaymentSettlementUnit(effectivePaymentMethod)
  const paymentTopupRatio = getPaymentTopupRatio(effectivePaymentMethod)
  const selectedPaymentMethodName =
    effectivePaymentMethod?.name ?? t('Payment Method')
  const shouldShowSettlementRule = (paymentMethod: PaymentMethod) =>
    !usesDedicatedPaymentPricing(paymentMethod.type)
  const getSettlementRule = (paymentMethod: PaymentMethod) => {
    const configuredRate = formatPaymentSettlementRate(paymentMethod)
    if (configuredRate) return configuredRate

    return t('Global settlement')
  }
  const formatSelectedPaymentAmount = (amount: number) =>
    settlementUnit
      ? formatSettlementAmount(amount, settlementUnit.label)
      : formatPaymentAmount(amount)
  const formatPresetPaymentAmount = (amount: number) =>
    settlementUnit
      ? formatSettlementAmount(amount, settlementUnit.label)
      : formatPaymentAmount(amount)
  const pancakeCurrencySupported = isWaffoPancakeCurrencySupported()
  const selectedPresetPricing = (() => {
    if (selectedPreset === null) return null
    const preset = presetAmounts.find((item) => item.value === selectedPreset)
    if (!preset) return null
    const discount =
      preset.discount || topupInfo?.discount?.[preset.value] || 1.0
    return calculatePresetPricing(
      preset.value,
      (settlementUnit?.unitPrice ?? priceRatio) *
        topupGroupRatio *
        paymentTopupRatio,
      discount
    )
  })()

  if (loading) {
    return (
      <Card data-card-hover='false' className='gap-0 overflow-hidden py-0'>
        <CardHeader className='border-b p-3 !pb-3 sm:p-5 sm:!pb-5'>
          <Skeleton className='h-6 w-32' />
          <Skeleton className='mt-2 h-4 w-48' />
        </CardHeader>
        <CardContent className='space-y-4 p-3 sm:space-y-6 sm:p-5'>
          <div className='space-y-4 sm:space-y-6'>
            {/* Preset Amounts Skeleton */}
            <div className='space-y-3'>
              <Skeleton className='h-3 w-16' />
              <div className='grid grid-cols-2 gap-3 sm:grid-cols-4'>
                {Array.from({ length: 8 }, (_, index) => `preset-${index}`).map(
                  (key) => (
                    <Skeleton key={key} className='h-[72px] rounded-lg' />
                  )
                )}
              </div>
            </div>

            {/* Custom Amount Input Skeleton */}
            <div className='space-y-3'>
              <Skeleton className='h-3 w-28' />
              <Skeleton className='h-[42px] w-full' />
            </div>

            {/* Payment Methods Skeleton */}
            <div className='space-y-3'>
              <Skeleton className='h-3 w-32' />
              <div className='flex flex-wrap gap-3'>
                {['primary', 'secondary', 'tertiary'].map((key) => (
                  <Skeleton key={key} className='h-10 w-24 rounded-lg' />
                ))}
              </div>
            </div>
          </div>

          {/* Redemption Code Section Skeleton */}
          <div className='space-y-3 border-t pt-8'>
            <Skeleton className='h-3 w-24' />
            <div className='flex gap-2'>
              <Skeleton className='h-10 flex-1' />
              <Skeleton className='h-10 w-20' />
            </div>
          </div>
        </CardContent>
      </Card>
    )
  }

  return (
    <TitledCard
      title={t('Add Funds')}
      description={t('Choose an amount and payment method')}
      icon={<HugeiconsIcon icon={WalletCardsIcon} strokeWidth={2} />}
      iconTone='success'
      disableHoverEffect
      action={
        onOpenBilling ? (
          <Button
            variant='outline'
            size='sm'
            onClick={onOpenBilling}
            className='w-full gap-2 sm:w-auto'
          >
            <HugeiconsIcon icon={Invoice01Icon} data-icon='inline-start' />
            {t('Order History')}
          </Button>
        ) : null
      }
      contentClassName='space-y-4 sm:space-y-6'
    >
      {/* Online Topup Section */}
      {hasAnyTopup ? (
        <div className='space-y-4 sm:space-y-6'>
          {hasConfigurableTopup && (
            <>
              {presetAmounts.length > 0 && (
                <FieldGroup>
                  <Field>
                    <FieldLabel>{t('Credited amount (unit: USD)')}</FieldLabel>
                    <FieldDescription>
                      {t(
                        'Credits are added to your current signed-in account for API usage.'
                      )}
                    </FieldDescription>
                    <div className='grid grid-cols-2 gap-2'>
                      {presetAmounts.map((preset) => {
                        const discount =
                          preset.discount ||
                          topupInfo?.discount?.[preset.value] ||
                          1.0
                        const defaultPricing = calculatePresetPricing(
                          preset.value,
                          priceRatio * topupGroupRatio * paymentTopupRatio,
                          discount
                        )
                        const configuredSettlementPrice = settlementUnit
                          ? calculatePresetPricing(
                              preset.value,
                              settlementUnit.unitPrice *
                                topupGroupRatio *
                                paymentTopupRatio,
                              discount
                            )
                          : null
                        const {
                          originalPrice,
                          actualPrice,
                          savedAmount,
                          hasDiscount,
                        } = configuredSettlementPrice
                          ? {
                              ...configuredSettlementPrice,
                              hasDiscount: discount < 1,
                            }
                          : defaultPricing
                        const credits = formatCreditBalance(preset.value)
                        const payment = formatPresetPaymentAmount(actualPrice)
                        const originalPayment =
                          formatPresetPaymentAmount(originalPrice)
                        const discountPercent = Math.round((1 - discount) * 100)
                        const discountSummary = hasDiscount
                          ? `${t('Platform discount {{percent}}%', {
                              percent: discountPercent,
                            })}. ${t('Discount applied {{amount}}', {
                              amount: formatPresetPaymentAmount(savedAmount),
                            })}`
                          : t('Platform discount {{percent}}%', { percent: 0 })
                        return (
                          <Button
                            key={preset.value}
                            variant='outline'
                            className={cn(
                              'flex min-h-32 min-w-0 flex-col items-start rounded-lg px-3 py-2.5 text-left whitespace-normal sm:min-h-24 sm:p-4',
                              selectedPreset === preset.value
                                ? 'border-primary bg-primary/5'
                                : 'border-muted'
                            )}
                            onClick={() => onSelectPreset(preset)}
                            aria-pressed={selectedPreset === preset.value}
                            aria-label={t(
                              'Preset amount: {{credit}}. Actual payment: {{payment}}. Original payment: {{original}}. {{discount}}',
                              {
                                credit: credits,
                                payment,
                                original: originalPayment,
                                discount: discountSummary,
                              }
                            )}
                          >
                            <div className='flex w-full min-w-0 flex-col items-start gap-1 sm:flex-row sm:items-center sm:justify-between'>
                              <div className='min-w-0 text-base font-semibold sm:text-lg'>
                                {formatCreditValue(preset.value)}
                                <span className='text-muted-foreground text-xs font-normal sm:text-sm'>
                                  {t('(Platform amount, unit: USD)')}
                                </span>
                              </div>
                              {hasDiscount && (
                                <Badge variant='secondary'>
                                  {t('Platform discount {{percent}}%', {
                                    percent: discountPercent,
                                  })}
                                </Badge>
                              )}
                            </div>
                          </Button>
                        )
                      })}
                    </div>
                    <Card className='bg-muted/30 border-dashed shadow-none'>
                      <CardContent className='space-y-1.5 p-3 text-xs sm:p-4'>
                        <div className='font-medium'>{t('Payment notes')}</div>
                        <p className='text-muted-foreground'>
                          {t(
                            'The amount shown on each card is the platform credit. The actual payment and any discount are calculated for the selected payment method.'
                          )}
                        </p>
                        {selectedPreset !== null && (
                          <>
                            <p className='text-muted-foreground'>
                              {t(
                                'Selected method: {{method}} · Estimated payment: {{amount}} (original {{original}})',
                                {
                                  method: selectedPaymentMethodName,
                                  amount: formatPresetPaymentAmount(
                                    selectedPresetPricing?.actualPrice ?? 0
                                  ),
                                  original: formatPresetPaymentAmount(
                                    selectedPresetPricing?.originalPrice ?? 0
                                  ),
                                }
                              )}
                            </p>
                            {selectedPresetPricing?.hasDiscount && (
                              <p className='text-muted-foreground'>
                                {t('Discount applied {{amount}}', {
                                  amount: formatPresetPaymentAmount(
                                    selectedPresetPricing.savedAmount
                                  ),
                                })}
                              </p>
                            )}
                          </>
                        )}
                      </CardContent>
                    </Card>
                  </Field>
                </FieldGroup>
              )}

              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor='topup-amount'>
                    {t('Custom credited amount')}
                  </FieldLabel>
                  <FieldDescription id='topup-amount-description'>
                    {t(
                      'Destination: current signed-in account · API usage balance'
                    )}
                  </FieldDescription>
                  <div className='grid min-w-0 gap-2 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center'>
                    <InputGroup className='h-9 sm:h-10'>
                      <InputGroupAddon aria-hidden='true'>$</InputGroupAddon>
                      <InputGroupInput
                        id='topup-amount'
                        type='number'
                        value={localAmount}
                        onChange={(e) => handleAmountChange(e.target.value)}
                        min={minTopup}
                        placeholder={t('Minimum {{amount}}', {
                          amount: minTopup,
                        })}
                        aria-describedby='topup-amount-description'
                        aria-label={t('Custom credited amount in US dollars')}
                        className='text-base sm:text-lg'
                      />
                      <InputGroupAddon align='inline-end' aria-hidden='true'>
                        USD
                      </InputGroupAddon>
                    </InputGroup>
                    <div className='bg-muted flex min-h-9 min-w-0 items-center justify-between gap-2 rounded-md border px-3 lg:min-w-52'>
                      <div className='flex min-w-0 flex-col gap-1 py-1'>
                        <span className='text-muted-foreground text-xs'>
                          {t(
                            'Selected method: {{method}} · Amount due: {{amount}} (actual payment)',
                            {
                              method: selectedPaymentMethodName,
                              amount:
                                formatSelectedPaymentAmount(paymentAmount),
                            }
                          )}
                        </span>
                        <div className='flex flex-wrap gap-1'>
                          <Badge variant='secondary'>
                            {t('Platform discount {{percent}}%', {
                              percent: Math.round((1 - customDiscount) * 100),
                            })}
                          </Badge>
                          {customHasDiscount && customDiscountAmount > 0 && (
                            <Badge variant='outline'>
                              {t('Discount applied {{amount}}', {
                                amount:
                                  formatSelectedPaymentAmount(
                                    customDiscountAmount
                                  ),
                              })}
                            </Badge>
                          )}
                        </div>
                      </div>
                      {calculating ? <Skeleton className='h-5 w-16' /> : null}
                    </div>
                  </div>
                </Field>
              </FieldGroup>

              <FieldGroup>
                <Field>
                  <Label className='text-muted-foreground text-xs font-medium tracking-wider uppercase'>
                    {t('Payment Method')}
                  </Label>
                  {hasStandardPaymentMethods ? (
                    <div className='grid grid-cols-2 gap-1.5 sm:gap-3 lg:grid-cols-3'>
                      {topupInfo?.pay_methods?.map((method) => {
                        const minTopup = Math.max(
                          method.min_topup || 0,
                          getMinTopupAmount(topupInfo)
                        )
                        const disabled = minTopup > topupAmount
                        const disabledReason = disabled
                          ? t('Minimum topup amount: {{amount}}', {
                              amount: minTopup,
                            })
                          : undefined
                        const disabledLabel = disabled
                          ? `${t('Minimum:')} ${minTopup}`
                          : undefined
                        const settlementRule = shouldShowSettlementRule(method)
                          ? getSettlementRule(method)
                          : null
                        const methodTopupRatio = getPaymentTopupRatio(method)

                        const button = (
                          <Button
                            key={method.type}
                            variant='outline'
                            onClick={() => onPaymentMethodSelect(method)}
                            disabled={disabled || !!paymentLoading}
                            title={disabledReason}
                            aria-label={
                              disabledReason
                                ? `${method.name}. ${disabledReason}`
                                : method.name
                            }
                            className='min-h-14 min-w-0 justify-start gap-2 rounded-lg px-3 py-2 text-left'
                          >
                            {paymentLoading === method.type ? (
                              <HugeiconsIcon
                                icon={Loading03Icon}
                                className='animate-spin'
                                data-icon='inline-start'
                              />
                            ) : (
                              getPaymentIcon(
                                method.type,
                                'h-4 w-4',
                                method.icon,
                                method.name
                              )
                            )}
                            <span className='flex min-w-0 flex-col items-start gap-0.5'>
                              <span className='max-w-full truncate'>
                                {method.name}
                              </span>
                              {disabledLabel && (
                                <span className='text-muted-foreground max-w-full truncate text-[11px] leading-4 font-normal'>
                                  {disabledLabel}
                                </span>
                              )}
                              {settlementRule && (
                                <span className='text-muted-foreground max-w-full truncate text-[11px] leading-4 font-normal'>
                                  {settlementRule}
                                </span>
                              )}
                              {methodTopupRatio !== 1 && (
                                <span className='text-muted-foreground max-w-full truncate text-[11px] leading-4 font-normal'>
                                  {t('Channel multiplier ×{{ratio}}', {
                                    ratio: method.topup_ratio,
                                  })}
                                </span>
                              )}
                            </span>
                          </Button>
                        )

                        return disabled ? (
                          <TooltipProvider key={method.type}>
                            <Tooltip>
                              <TooltipTrigger render={button} />
                              <TooltipContent>{disabledReason}</TooltipContent>
                            </Tooltip>
                          </TooltipProvider>
                        ) : (
                          button
                        )
                      })}
                    </div>
                  ) : null}
                  {!hasStandardPaymentMethods && !hasWaffoPaymentMethods && (
                    <Alert>
                      <AlertDescription>
                        {t(
                          'No payment methods available. Please contact administrator.'
                        )}
                      </AlertDescription>
                    </Alert>
                  )}
                  {enableWaffoPancakeTopup && !pancakeCurrencySupported && (
                    <Alert>
                      <AlertDescription>
                        {t(
                          'Waffo Pancake currently supports USD only. Please set this gateway currency to USD.'
                        )}
                      </AlertDescription>
                    </Alert>
                  )}
                </Field>
              </FieldGroup>

              {enableWaffoTopup &&
                hasWaffoPaymentMethods &&
                onWaffoMethodSelect && (
                  <div className='space-y-2.5 sm:space-y-3'>
                    <Label className='text-muted-foreground text-xs font-medium tracking-wider uppercase'>
                      {t('Waffo Payment')}
                    </Label>
                    <div className='grid grid-cols-2 gap-1.5 sm:gap-3 lg:grid-cols-3'>
                      {waffoPayMethods?.map((method, index) => {
                        const loadingKey = `waffo-${index}`
                        const methodKey = `${method.payMethodType ?? 'unknown'}-${method.payMethodName ?? method.name}`
                        const waffoMin = waffoMinTopup || 0
                        const belowMin = waffoMin > topupAmount
                        const disabledReason = belowMin
                          ? t('Minimum topup amount: {{amount}}', {
                              amount: waffoMin,
                            })
                          : undefined
                        const disabledLabel = belowMin
                          ? `${t('Minimum:')} ${waffoMin}`
                          : undefined

                        let methodIcon = getPaymentIcon('waffo')
                        if (paymentLoading === loadingKey) {
                          methodIcon = (
                            <HugeiconsIcon
                              icon={Loading03Icon}
                              className='animate-spin'
                              data-icon='inline-start'
                            />
                          )
                        } else if (method.icon) {
                          methodIcon = (
                            <img
                              src={method.icon}
                              alt={method.name}
                              className='h-4 w-4 object-contain'
                            />
                          )
                        }

                        const button = (
                          <Button
                            key={methodKey}
                            variant='outline'
                            onClick={() => onWaffoMethodSelect(method, index)}
                            disabled={belowMin || !!paymentLoading}
                            title={disabledReason}
                            aria-label={
                              disabledReason
                                ? `${method.name}. ${disabledReason}`
                                : method.name
                            }
                            className='min-h-14 min-w-0 justify-start gap-2 rounded-lg px-3 py-2 text-left'
                          >
                            {methodIcon}
                            <span className='flex min-w-0 flex-col items-start gap-0.5'>
                              <span className='max-w-full truncate'>
                                {method.name}
                              </span>
                              {disabledLabel && (
                                <span className='text-muted-foreground max-w-full truncate text-[11px] leading-4 font-normal'>
                                  {disabledLabel}
                                </span>
                              )}
                            </span>
                          </Button>
                        )

                        return belowMin ? (
                          <TooltipProvider key={methodKey}>
                            <Tooltip>
                              <TooltipTrigger render={button} />
                              <TooltipContent>{disabledReason}</TooltipContent>
                            </Tooltip>
                          </TooltipProvider>
                        ) : (
                          button
                        )
                      })}
                    </div>
                  </div>
                )}
            </>
          )}
        </div>
      ) : (
        <Alert>
          <AlertDescription>
            {t(
              'Online topup is not enabled. Please use redemption code or contact administrator.'
            )}
          </AlertDescription>
        </Alert>
      )}

      {/* Creem Products Section */}
      {enableCreemTopup &&
        Array.isArray(creemProducts) &&
        creemProducts.length > 0 &&
        onCreemProductSelect && (
          <div className='flex flex-col gap-3 pt-4 sm:pt-6'>
            <Separator />
            <Label className='text-muted-foreground text-xs font-medium tracking-wider uppercase'>
              {t('Creem Payment')}
            </Label>
            <CreemProductsSection
              products={creemProducts}
              onProductSelect={onCreemProductSelect}
            />
          </div>
        )}

      {/* Redemption Code Section */}
      {redemptionEnabled ? (
        <div className='flex flex-col gap-3 pt-4 sm:pt-6'>
          <Separator />
          <div className='flex items-center gap-2'>
            <IconBadge tone='warning' size='xs'>
              <HugeiconsIcon icon={GiftIcon} strokeWidth={2} />
            </IconBadge>
            <Label
              htmlFor='redemption-code'
              className='text-muted-foreground text-xs font-medium tracking-wider uppercase'
            >
              {t('Have a Code?')}
            </Label>
          </div>
          <div className='grid grid-cols-[minmax(0,1fr)_auto] gap-2'>
            <Input
              id='redemption-code'
              value={redemptionCode}
              onChange={(e) => onRedemptionCodeChange(e.target.value)}
              placeholder={t('Enter your redemption code')}
              className='h-9 min-w-0'
            />
            <Button
              onClick={onRedeem}
              disabled={redeeming}
              variant='outline'
              className='h-9 px-4'
            >
              {redeeming && (
                <HugeiconsIcon
                  icon={Loading03Icon}
                  className='animate-spin'
                  data-icon='inline-start'
                />
              )}
              {t('Redeem')}
            </Button>
          </div>
          {topupLink && (
            <p className='text-muted-foreground text-xs'>
              {t('Need a redemption code?')}{' '}
              <a
                href={topupLink}
                target='_blank'
                rel='noopener noreferrer'
                className='inline-flex items-center gap-1 underline-offset-4 hover:underline'
              >
                {t('Get one here')}
                <HugeiconsIcon icon={ExternalLinkIcon} data-icon='inline-end' />
              </a>
            </p>
          )}
        </div>
      ) : (
        <Alert className='border-t'>
          <AlertDescription>
            {t(
              'Redemption codes are disabled until the administrator confirms compliance terms.'
            )}
          </AlertDescription>
        </Alert>
      )}
    </TitledCard>
  )
}
