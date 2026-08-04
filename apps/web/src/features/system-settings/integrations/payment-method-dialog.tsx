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
import { zodResolver } from '@hookform/resolvers/zod'
import { useEffect } from 'react'
import { useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import * as z from 'zod'

import { Dialog } from '@/components/dialog'
import { ReactIconByName } from '@/components/react-icon-by-name'
import { Button } from '@/components/ui/button'
import { Combobox } from '@/components/ui/combobox'
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form'
import { Input } from '@/components/ui/input'
import { usesDedicatedPaymentPricing } from '@/lib/payment-pricing'

import { getPaymentMethodRatePresets } from './payment-method-rate-presets'

const SETTLEMENT_UNIT_PATTERN = /^[A-Za-z0-9._-]{1,16}$/
const POSITIVE_DECIMAL_PATTERN = /^[0-9]+(?:\.[0-9]+)?$/

const createPaymentMethodDialogSchema = (t: (key: string) => string) =>
  z
    .object({
      name: z.string().min(1, t('Payment method name is required')),
      type: z.string().min(1, t('Payment type key is required')),
      icon: z.string().optional(),
      min_topup: z.string().optional(),
      topup_ratio: z
        .string()
        .optional()
        .refine(
          (value) => {
            if (!value?.trim()) return true
            const trimmed = value.trim()
            return POSITIVE_DECIMAL_PATTERN.test(trimmed) && Number(trimmed) > 0
          },
          { message: t('Payment multiplier must be a positive decimal number') }
        ),
      settlement_unit: z
        .string()
        .optional()
        .refine(
          (value) =>
            !value?.trim() || SETTLEMENT_UNIT_PATTERN.test(value.trim()),
          {
            message: t(
              'Settlement unit must use only letters, numbers, dots, hyphens, or underscores (max 16 characters)'
            ),
          }
        ),
      unit_price: z
        .string()
        .optional()
        .refine(
          (value) => {
            if (!value?.trim()) return true
            const trimmed = value.trim()
            return POSITIVE_DECIMAL_PATTERN.test(trimmed) && Number(trimmed) > 0
          },
          { message: t('Gateway price must be a positive decimal number') }
        ),
    })
    .superRefine((values, ctx) => {
      const hasSettlementUnit = !!values.settlement_unit?.trim()
      const hasUnitPrice = !!values.unit_price?.trim()

      if (hasSettlementUnit && !hasUnitPrice) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: t('Set a valid gateway price when a settlement unit is set'),
          path: ['unit_price'],
        })
      }
      if (hasUnitPrice && !hasSettlementUnit) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: t('Set a settlement unit when a gateway price is set'),
          path: ['settlement_unit'],
        })
      }
    })

type PaymentMethodDialogFormValues = z.infer<
  ReturnType<typeof createPaymentMethodDialogSchema>
>

const PAYMENT_METHOD_FORM_ID = 'payment-method-form'

export type PaymentMethodData = {
  name: string
  type: string
  icon?: string
  min_topup?: string
  topup_ratio?: string
  settlement_unit?: string
  unit_price?: string
  color?: string
}

type PaymentMethodDialogProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  onSave: (data: PaymentMethodData) => void
  editData?: PaymentMethodData | null
  globalPrice: number
}

const PAYMENT_TYPE_ICON_NAMES: Record<string, string> = {
  alipay: 'SiAlipay',
  epay: 'SiLinux',
  stripe: 'SiStripe',
  wxpay: 'SiWechat',
}

const getDefaultIconName = (type: string) => PAYMENT_TYPE_ICON_NAMES[type] ?? ''

export function PaymentMethodDialog({
  open,
  onOpenChange,
  onSave,
  editData,
  globalPrice,
}: PaymentMethodDialogProps) {
  const { t } = useTranslation()
  const isEditMode = !!editData
  const paymentMethodDialogSchema = createPaymentMethodDialogSchema(t)
  const paymentTypeOptions = [
    {
      iconName: 'SiAlipay',
      label: `${t('Alipay')} (Epay: alipay)`,
      name: t('Alipay'),
      value: 'alipay',
    },
    {
      iconName: 'SiWechat',
      label: `${t('WeChat Pay')} (Epay: wxpay)`,
      name: t('WeChat Pay'),
      value: 'wxpay',
    },
    {
      iconName: 'SiStripe',
      label: `${t('Stripe')} (stripe)`,
      name: t('Stripe'),
      value: 'stripe',
    },
    {
      iconName: 'SiLinux',
      label: 'LINUX DO Credit (Epay: epay)',
      name: 'LINUX DO Credit',
      value: 'epay',
    },
    {
      iconName: '',
      label: 'Waffo Pancake (waffo_pancake)',
      name: 'Waffo Pancake',
      value: 'waffo_pancake',
    },
  ]
  const getPaymentTypeOption = (value: string) =>
    paymentTypeOptions.find((option) => option.value === value)

  const form = useForm<PaymentMethodDialogFormValues>({
    resolver: zodResolver(paymentMethodDialogSchema),
    defaultValues: {
      name: '',
      type: '',
      icon: '',
      min_topup: '',
      topup_ratio: '',
      settlement_unit: '',
      unit_price: '',
    },
  })

  const iconValue = form.watch('icon')
  const selectedType = form.watch('type')
  const settlementUnitValue = form.watch('settlement_unit')?.trim()
  const unitPriceValue = form.watch('unit_price')?.trim()
  const usesDedicatedPricing = usesDedicatedPaymentPricing(selectedType)
  const ratePresets = getPaymentMethodRatePresets(globalPrice)

  useEffect(() => {
    if (editData) {
      form.reset({
        name: editData.name,
        type: editData.type,
        icon: editData.icon ?? getDefaultIconName(editData.type),
        min_topup: editData.min_topup ?? '',
        topup_ratio: editData.topup_ratio ?? '',
        settlement_unit: editData.settlement_unit ?? '',
        unit_price: editData.unit_price ?? '',
      })
    } else {
      form.reset({
        name: '',
        type: '',
        icon: '',
        min_topup: '',
        topup_ratio: '',
        settlement_unit: '',
        unit_price: '',
      })
    }
  }, [editData, form, open])

  const handleSubmit = (values: PaymentMethodDialogFormValues) => {
    const data: PaymentMethodData = {
      name: values.name,
      type: values.type,
    }
    if (values.icon && values.icon.trim() !== '') {
      data.icon = values.icon.trim()
    }
    if (values.min_topup && values.min_topup.trim() !== '') {
      data.min_topup = values.min_topup
    }
    if (
      !usesDedicatedPaymentPricing(values.type) &&
      values.topup_ratio &&
      values.topup_ratio.trim() !== ''
    ) {
      data.topup_ratio = values.topup_ratio.trim()
    }
    if (
      !usesDedicatedPaymentPricing(values.type) &&
      values.settlement_unit &&
      values.settlement_unit.trim() !== ''
    ) {
      data.settlement_unit = values.settlement_unit.trim()
    }
    if (
      !usesDedicatedPaymentPricing(values.type) &&
      values.unit_price &&
      values.unit_price.trim() !== ''
    ) {
      data.unit_price = values.unit_price.trim()
    }
    onSave(data)
    form.reset()
    onOpenChange(false)
  }

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title={isEditMode ? t('Edit payment method') : t('Add payment method')}
      description={t('Configure a payment method for user recharge options.')}
      contentClassName='sm:max-w-[500px]'
      contentHeight='auto'
      bodyClassName='space-y-4'
      footer={
        <>
          <Button
            type='button'
            variant='outline'
            onClick={() => onOpenChange(false)}
          >
            {t('Cancel')}
          </Button>
          <Button type='submit' form={PAYMENT_METHOD_FORM_ID}>
            {isEditMode ? t('Update') : t('Add')}
          </Button>
        </>
      }
    >
      <Form {...form}>
        <form
          id={PAYMENT_METHOD_FORM_ID}
          onSubmit={form.handleSubmit(handleSubmit)}
          className='space-y-4'
        >
          <FormField
            control={form.control}
            name='name'
            render={({ field }) => (
              <FormItem>
                <FormLabel>{t('Name')}</FormLabel>
                <FormControl>
                  <Input placeholder={t('e.g., Alipay, WeChat')} {...field} />
                </FormControl>
                <FormDescription>
                  {t('Display name for this payment method.')}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name='type'
            render={({ field }) => (
              <FormItem>
                <FormLabel>{t('Payment type key')}</FormLabel>
                <FormControl>
                  <Combobox
                    options={paymentTypeOptions}
                    value={field.value}
                    onValueChange={(value) => {
                      if (value === null) return
                      const currentIcon = form.getValues('icon')?.trim()
                      const currentName = form.getValues('name')?.trim()
                      const previousOption = getPaymentTypeOption(field.value)
                      const nextOption = getPaymentTypeOption(value)

                      field.onChange(value)
                      if (usesDedicatedPaymentPricing(value)) {
                        form.setValue('topup_ratio', '', {
                          shouldDirty: true,
                          shouldValidate: true,
                        })
                        form.setValue('settlement_unit', '', {
                          shouldDirty: true,
                          shouldValidate: true,
                        })
                        form.setValue('unit_price', '', {
                          shouldDirty: true,
                          shouldValidate: true,
                        })
                      }
                      if (
                        nextOption?.iconName &&
                        (!currentIcon ||
                          currentIcon === previousOption?.iconName)
                      ) {
                        form.setValue('icon', nextOption.iconName, {
                          shouldDirty: true,
                        })
                      }
                      if (
                        nextOption?.name &&
                        (!currentName || currentName === previousOption?.name)
                      ) {
                        form.setValue('name', nextOption.name, {
                          shouldDirty: true,
                        })
                      }
                    }}
                    placeholder={t('Select or enter payment type key')}
                    searchPlaceholder={t('Search payment type keys...')}
                    allowCustomValue
                  />
                </FormControl>
                <FormDescription className='leading-relaxed'>
                  {t(
                    'Used to decide the payment flow. Built-in keys include stripe for Stripe and waffo_pancake for Waffo Pancake; other values are sent to Epay as the type parameter.'
                  )}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name='icon'
            render={({ field }) => (
              <FormItem>
                <FormLabel>{t('Icon')}</FormLabel>
                <FormControl>
                  <div className='flex items-center gap-2'>
                    <Input
                      placeholder={t('e.g., SiAlipay')}
                      {...field}
                      className='flex-1'
                    />
                    {iconValue && (
                      <ReactIconByName
                        name={iconValue}
                        className='text-muted-foreground size-5 shrink-0'
                        title={iconValue}
                      />
                    )}
                  </div>
                </FormControl>
                <FormDescription>
                  {t(
                    'Enter a react-icons component name. Invalid names show no icon.'
                  )}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name='min_topup'
            render={({ field }) => (
              <FormItem>
                <FormLabel>{t('Minimum top-up (optional)')}</FormLabel>
                <FormControl>
                  <Input
                    type='number'
                    step='0.01'
                    placeholder={t('e.g., 50')}
                    {...field}
                  />
                </FormControl>
                <FormDescription>
                  {t('Optional minimum recharge amount for this method.')}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          {!usesDedicatedPricing && (
            <FormField
              control={form.control}
              name='topup_ratio'
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{t('Payment multiplier (optional)')}</FormLabel>
                  <FormControl>
                    <Input
                      type='number'
                      min='0.000000000001'
                      step='any'
                      placeholder='1'
                      {...field}
                    />
                  </FormControl>
                  <FormDescription>
                    {t(
                      "Multiplied with the user's group top-up multiplier. Leave empty for 1."
                    )}
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />
          )}

          {usesDedicatedPricing ? (
            <div className='bg-muted/40 rounded-md border p-3 text-sm'>
              <p className='font-medium'>{t('Dedicated gateway pricing')}</p>
              <p className='text-muted-foreground mt-1 text-xs leading-relaxed'>
                {t(
                  'This payment flow uses its dedicated gateway price setting, so per-method settlement pricing is not applied here.'
                )}
              </p>
            </div>
          ) : (
            <>
              <FormField
                control={form.control}
                name='settlement_unit'
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>{t('Settlement unit (optional)')}</FormLabel>
                    <FormControl>
                      <Input placeholder='LDC' {...field} />
                    </FormControl>
                    <FormDescription>
                      {t(
                        'The gateway currency label shown to users, for example LDC.'
                      )}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name='unit_price'
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>
                      {t('Gateway price per 1 USD (optional)')}
                    </FormLabel>
                    <FormControl>
                      <Input
                        type='number'
                        min='0.000000000001'
                        step='any'
                        placeholder='10'
                        {...field}
                      />
                    </FormControl>
                    <FormDescription>
                      {t(
                        'The server uses this price to quote and verify payment. Example: 10 means 10 LDC for 1 USD.'
                      )}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <div className='bg-muted/30 space-y-2 rounded-md border p-3'>
                <div>
                  <p className='text-sm font-medium'>
                    {t('Channel price presets')}
                  </p>
                  <p className='text-muted-foreground text-xs leading-relaxed'>
                    {t(
                      'Choose a preset or enter any positive decimal. The settlement unit and price must be configured together.'
                    )}
                  </p>
                </div>
                <div className='grid gap-2 sm:grid-cols-2'>
                  <Button
                    type='button'
                    size='sm'
                    variant='outline'
                    disabled={!ratePresets}
                    onClick={() => {
                      if (!ratePresets) return
                      form.setValue(
                        'unit_price',
                        ratePresets.currentGlobalPrice,
                        { shouldDirty: true, shouldValidate: true }
                      )
                    }}
                  >
                    {t('Use global price')}
                    {ratePresets ? ` · ${ratePresets.currentGlobalPrice}` : ''}
                  </Button>
                  <Button
                    type='button'
                    size='sm'
                    variant='outline'
                    disabled={!ratePresets}
                    onClick={() => {
                      if (!ratePresets) return
                      form.setValue(
                        'unit_price',
                        ratePresets.reciprocalGlobalPrice,
                        { shouldDirty: true, shouldValidate: true }
                      )
                    }}
                  >
                    {t('Use global price reciprocal')}
                    {ratePresets
                      ? ` · ${ratePresets.reciprocalGlobalPrice}`
                      : ''}
                  </Button>
                </div>
                {ratePresets ? (
                  <p className='text-muted-foreground text-xs leading-relaxed'>
                    {t(
                      'Reciprocal preview: 1 ÷ {{price}} = {{reciprocal}}. This reverses the configured price direction; verify the settlement preview before saving.',
                      {
                        price: ratePresets.currentGlobalPrice,
                        reciprocal: ratePresets.reciprocalGlobalPrice,
                      }
                    )}
                  </p>
                ) : (
                  <p className='text-destructive text-xs'>
                    {t('Set a positive global price to use rate presets.')}
                  </p>
                )}
                {settlementUnitValue && unitPriceValue ? (
                  <p className='text-sm font-medium'>
                    {t(
                      'Settlement preview: 1 platform USD = {{price}} {{unit}}',
                      {
                        price: unitPriceValue,
                        unit: settlementUnitValue,
                      }
                    )}
                  </p>
                ) : null}
              </div>
            </>
          )}
        </form>
      </Form>
    </Dialog>
  )
}
