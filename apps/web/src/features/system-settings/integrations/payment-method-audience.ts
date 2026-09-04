type PaymentMethodAudienceRoleOption = {
  label: string
  value: string
}

export const getPaymentMethodAudienceRoleOptions = (
  t: (key: string) => string
): PaymentMethodAudienceRoleOption[] => [
  { label: t('No role condition'), value: 'none' },
  { label: t('Common User'), value: 'common' },
  { label: t('Administrator'), value: 'admin' },
  { label: t('Root administrator'), value: 'root' },
]
