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
import {
  Copy01Icon,
  CustomerSupportIcon,
  HelpCircleIcon,
  InformationCircleIcon,
  Invoice02Icon,
  MailSend01Icon,
  MoneyReceiveCircleIcon,
  ReceiptDollarIcon,
  UserShield01Icon,
  Wrench01Icon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { Controller, useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'
import { z } from 'zod'

import { Main } from '@/components/layout'
import {
  CardStaggerContainer,
  CardStaggerItem,
} from '@/components/page-transition'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import {
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { TitledCard } from '@/components/ui/titled-card'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { useAuthStore } from '@/stores/auth-store'

import {
  buildSupportMailto,
  buildSupportTicketText,
  SUPPORT_EMAIL,
} from './lib'
import {
  SUPPORT_TICKET_CATEGORIES,
  type SupportTicketCategory,
  type SupportTicketDraft,
  type SupportTicketLabels,
} from './types'

const supportTicketSchema = z.object({
  category: z.enum(SUPPORT_TICKET_CATEGORIES),
  contactEmail: z.string().trim().email('Enter a valid contact email'),
  referenceId: z.string().trim().max(120, 'Reference ID is too long'),
  subject: z
    .string()
    .trim()
    .min(4, 'Subject must be at least 4 characters')
    .max(100, 'Subject must be at most 100 characters'),
  details: z
    .string()
    .trim()
    .min(20, 'Details must be at least 20 characters')
    .max(1200, 'Details must be at most 1200 characters'),
})

type SupportTicketForm = z.infer<typeof supportTicketSchema>

const CATEGORY_META = [
  {
    value: 'refund',
    labelKey: 'Refund request',
    descriptionKey: 'Request a refund for an eligible payment.',
    icon: MoneyReceiveCircleIcon,
  },
  {
    value: 'invoice',
    labelKey: 'Invoice request',
    descriptionKey: 'Ask for an invoice or billing document.',
    icon: Invoice02Icon,
  },
  {
    value: 'technical',
    labelKey: 'Technical support',
    descriptionKey: 'Get help with API errors or integration issues.',
    icon: Wrench01Icon,
  },
  {
    value: 'billing',
    labelKey: 'Billing issue',
    descriptionKey: 'Report an incorrect charge or balance.',
    icon: ReceiptDollarIcon,
  },
  {
    value: 'account',
    labelKey: 'Account & access',
    descriptionKey: 'Get help signing in or managing account access.',
    icon: UserShield01Icon,
  },
  {
    value: 'other',
    labelKey: 'Other request',
    descriptionKey: 'Contact support about something else.',
    icon: HelpCircleIcon,
  },
] as const satisfies ReadonlyArray<{
  value: SupportTicketCategory
  labelKey: string
  descriptionKey: string
  icon: typeof CustomerSupportIcon
}>

export function SupportTicket() {
  const { t } = useTranslation()
  const user = useAuthStore((state) => state.auth.user)
  const {
    control,
    register,
    handleSubmit,
    getValues,
    trigger,
    formState: { errors },
  } = useForm<SupportTicketForm>({
    resolver: zodResolver(supportTicketSchema),
    defaultValues: {
      category: 'technical',
      contactEmail: user?.email ?? '',
      referenceId: '',
      subject: '',
      details: '',
    },
  })

  const labels: SupportTicketLabels = {
    ticketType: t('Ticket type'),
    accountId: t('Account ID'),
    username: t('Username'),
    contactEmail: t('Contact email'),
    referenceId: t('Reference ID'),
    subject: t('Subject'),
    details: t('Details'),
  }

  const prepareTicket = (values: SupportTicketForm) => {
    const category = CATEGORY_META.find(
      (item) => item.value === values.category
    )
    const draft: SupportTicketDraft = {
      ...values,
      categoryLabel: t(category?.labelKey ?? 'Other request'),
    }
    const text = buildSupportTicketText(
      draft,
      { id: user?.id, username: user?.username },
      labels
    )
    const subject = `[${t('Support ticket')}] ${values.subject.trim()}`

    return { text, mailto: buildSupportMailto(subject, text) }
  }

  const submitTicket = handleSubmit((values) => {
    const { mailto } = prepareTicket(values)
    toast.info(t('Your email app will open with the ticket details filled in.'))
    window.location.assign(mailto)
  })

  const copyTicket = async () => {
    if (!(await trigger())) return

    try {
      const { text } = prepareTicket(getValues())
      await navigator.clipboard.writeText(text)
      toast.success(t('Ticket copied to clipboard'))
    } catch {
      toast.error(t('Unable to copy the ticket'))
    }
  }

  return (
    <Main>
      <div className='min-h-0 flex-1 overflow-auto px-3 py-3 sm:px-4 sm:py-6'>
        <CardStaggerContainer className='mx-auto flex w-full max-w-6xl flex-col gap-4 sm:gap-6'>
          <CardStaggerItem>
            <div className='flex items-start gap-3 sm:gap-4'>
              <div className='bg-primary/10 text-primary flex size-10 shrink-0 items-center justify-center rounded-xl sm:size-12'>
                <HugeiconsIcon
                  icon={CustomerSupportIcon}
                  strokeWidth={1.8}
                  className='size-5 sm:size-6'
                />
              </div>
              <div className='min-w-0'>
                <h1 className='text-xl font-bold tracking-tight sm:text-2xl'>
                  {t('Submit a ticket')}
                </h1>
                <p className='text-muted-foreground mt-1 max-w-2xl text-sm leading-relaxed'>
                  {t(
                    "Tell us what happened and we'll prepare a structured email for support."
                  )}
                </p>
              </div>
            </div>
          </CardStaggerItem>

          <CardStaggerItem>
            <div className='grid gap-4 sm:gap-6 lg:grid-cols-[minmax(0,1fr)_320px] lg:items-start'>
              <form onSubmit={submitTicket} noValidate>
                <TitledCard
                  title={t('Request details')}
                  description={t(
                    'Choose a topic and include enough context for support to investigate.'
                  )}
                  icon={
                    <HugeiconsIcon icon={MailSend01Icon} strokeWidth={1.8} />
                  }
                  iconTone='primary'
                  disableHoverEffect
                  contentClassName='p-3 sm:p-5'
                >
                  <FieldGroup>
                    <Controller
                      control={control}
                      name='category'
                      render={({ field }) => (
                        <FieldSet>
                          <FieldLegend variant='label'>
                            {t('Request type')}
                          </FieldLegend>
                          <FieldDescription>
                            {t(
                              'Choose the topic that best matches your request.'
                            )}
                          </FieldDescription>
                          <ToggleGroup
                            value={[field.value]}
                            onValueChange={(values) => {
                              const nextValue = values.find(
                                (value) => value !== field.value
                              ) as SupportTicketCategory | undefined
                              if (nextValue) field.onChange(nextValue)
                            }}
                            aria-label={t('Request type')}
                            variant='outline'
                            spacing={2}
                            className='grid w-full grid-cols-1 gap-2 sm:grid-cols-2 xl:grid-cols-3'
                          >
                            {CATEGORY_META.map((category) => (
                              <ToggleGroupItem
                                key={category.value}
                                value={category.value}
                                className='h-auto min-h-20 w-full items-start justify-start gap-3 px-3 py-3 text-start'
                              >
                                <HugeiconsIcon
                                  icon={category.icon}
                                  strokeWidth={1.8}
                                  className='mt-0.5 size-5 shrink-0'
                                />
                                <span className='min-w-0'>
                                  <span className='block text-sm font-semibold'>
                                    {t(category.labelKey)}
                                  </span>
                                  <span className='text-muted-foreground mt-0.5 block text-xs leading-snug font-normal text-wrap'>
                                    {t(category.descriptionKey)}
                                  </span>
                                </span>
                              </ToggleGroupItem>
                            ))}
                          </ToggleGroup>
                        </FieldSet>
                      )}
                    />

                    <div className='grid gap-5 sm:grid-cols-2'>
                      <Field
                        data-invalid={errors.contactEmail ? true : undefined}
                      >
                        <FieldLabel htmlFor='support-contact-email'>
                          {t('Contact email')}
                        </FieldLabel>
                        <Input
                          id='support-contact-email'
                          type='email'
                          autoComplete='email'
                          aria-invalid={errors.contactEmail ? true : undefined}
                          {...register('contactEmail')}
                        />
                        <FieldDescription>
                          {t("We'll use this address to reply.")}
                        </FieldDescription>
                        <FieldError>
                          {errors.contactEmail?.message
                            ? t(errors.contactEmail.message)
                            : null}
                        </FieldError>
                      </Field>

                      <Field
                        data-invalid={errors.referenceId ? true : undefined}
                      >
                        <FieldLabel htmlFor='support-reference-id'>
                          {t('Reference ID (optional)')}
                        </FieldLabel>
                        <Input
                          id='support-reference-id'
                          aria-invalid={errors.referenceId ? true : undefined}
                          placeholder={t('Order ID, request ID, or log ID')}
                          {...register('referenceId')}
                        />
                        <FieldDescription>
                          {t('This helps us find the relevant record faster.')}
                        </FieldDescription>
                        <FieldError>
                          {errors.referenceId?.message
                            ? t(errors.referenceId.message)
                            : null}
                        </FieldError>
                      </Field>
                    </div>

                    <Field data-invalid={errors.subject ? true : undefined}>
                      <FieldLabel htmlFor='support-subject'>
                        {t('Subject')}
                      </FieldLabel>
                      <Input
                        id='support-subject'
                        aria-invalid={errors.subject ? true : undefined}
                        placeholder={t('Briefly summarize your request')}
                        {...register('subject')}
                      />
                      <FieldError>
                        {errors.subject?.message
                          ? t(errors.subject.message)
                          : null}
                      </FieldError>
                    </Field>

                    <Field data-invalid={errors.details ? true : undefined}>
                      <FieldLabel htmlFor='support-details'>
                        {t('Details')}
                      </FieldLabel>
                      <Textarea
                        id='support-details'
                        rows={8}
                        aria-invalid={errors.details ? true : undefined}
                        placeholder={t(
                          'Describe the issue, what you expected, and what you already tried.'
                        )}
                        className='min-h-40 resize-y'
                        {...register('details')}
                      />
                      <FieldError>
                        {errors.details?.message
                          ? t(errors.details.message)
                          : null}
                      </FieldError>
                    </Field>

                    <Alert>
                      <HugeiconsIcon
                        icon={InformationCircleIcon}
                        strokeWidth={2}
                      />
                      <AlertDescription>
                        {t(
                          'Do not include passwords, full API keys, or payment card details.'
                        )}
                      </AlertDescription>
                    </Alert>

                    <div className='flex flex-col-reverse gap-2 sm:flex-row sm:justify-end'>
                      <Button
                        type='button'
                        variant='outline'
                        onClick={copyTicket}
                      >
                        <HugeiconsIcon
                          icon={Copy01Icon}
                          strokeWidth={2}
                          data-icon='inline-start'
                        />
                        {t('Copy request')}
                      </Button>
                      <Button type='submit'>
                        <HugeiconsIcon
                          icon={MailSend01Icon}
                          strokeWidth={2}
                          data-icon='inline-start'
                        />
                        {t('Open email to submit')}
                      </Button>
                    </div>
                  </FieldGroup>
                </TitledCard>
              </form>

              <aside className='space-y-4 lg:sticky lg:top-6'>
                <TitledCard
                  title={t('Before you submit')}
                  description={t(
                    'A few details can speed up the investigation.'
                  )}
                  icon={
                    <HugeiconsIcon
                      icon={InformationCircleIcon}
                      strokeWidth={1.8}
                    />
                  }
                  iconTone='info'
                  disableHoverEffect
                  contentClassName='p-3 sm:p-5'
                >
                  <ul className='text-muted-foreground space-y-3 text-sm leading-relaxed'>
                    <li>
                      {t('Include the relevant order, request, or log ID.')}
                    </li>
                    <li>
                      {t(
                        'For technical issues, include the model, endpoint, timestamp, and error message.'
                      )}
                    </li>
                    <li>
                      {t(
                        'You can attach screenshots or files in your email app.'
                      )}
                    </li>
                  </ul>
                </TitledCard>

                <TitledCard
                  title={t('Email support directly')}
                  description={SUPPORT_EMAIL}
                  icon={
                    <HugeiconsIcon
                      icon={CustomerSupportIcon}
                      strokeWidth={1.8}
                    />
                  }
                  iconTone='neutral'
                  disableHoverEffect
                  contentClassName='p-3 sm:p-5'
                >
                  <Button
                    variant='outline'
                    className='w-full'
                    render={<a href={`mailto:${SUPPORT_EMAIL}`} />}
                  >
                    <HugeiconsIcon
                      icon={MailSend01Icon}
                      strokeWidth={2}
                      data-icon='inline-start'
                    />
                    {t('Contact support')}
                  </Button>
                </TitledCard>
              </aside>
            </div>
          </CardStaggerItem>
        </CardStaggerContainer>
      </div>
    </Main>
  )
}
