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
  Key01Icon,
  ShieldCheck,
  ShieldKeyIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useNavigate } from '@tanstack/react-router'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { SectionPageLayout } from '@/components/layout'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Spinner } from '@/components/ui/spinner'
import { createApiKey } from '@/features/keys/api'
import { getSelf } from '@/lib/api'
import { isConsoleActivated } from '@/lib/console-activation'
import { useAuthStore } from '@/stores/auth-store'

export function DeveloperAccessPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const setUser = useAuthStore((state) => state.auth.setUser)
  const user = useAuthStore((state) => state.auth.user)
  const [name, setName] = useState('')
  const [submitting, setSubmitting] = useState(false)

  if (!isConsoleActivated(user)) {
    return (
      <SectionPageLayout>
        <SectionPageLayout.Title>{t('Account access')}</SectionPageLayout.Title>
        <SectionPageLayout.Content>
          <div className='bg-card mx-auto max-w-xl border p-7 sm:p-10'>
            <HugeiconsIcon
              icon={ShieldCheck}
              className='text-primary mb-6 size-9'
              strokeWidth={2}
              aria-hidden='true'
            />
            <h1 className='text-2xl font-semibold'>
              {t('Keep building trust')}
            </h1>
            <p className='text-muted-foreground mt-3 text-sm leading-6'>
              {t(
                'A funded, active account gradually unlocks more tools and better rates. Your current level is shown in the wallet.'
              )}
            </p>
            <Button
              className='mt-7'
              onClick={() => navigate({ to: '/wallet' })}
            >
              {t('View trust level')}
            </Button>
          </div>
        </SectionPageLayout.Content>
      </SectionPageLayout>
    )
  }

  const handleCreate = async () => {
    const credentialName = name.trim()
    if (!credentialName || submitting) return

    setSubmitting(true)
    try {
      const result = await createApiKey({
        name: credentialName,
        remain_quota: 0,
        expired_time: -1,
        unlimited_quota: true,
        model_limits_enabled: false,
        model_limits: '',
        allow_ips: '',
        group: 'default',
        cross_group_retry: false,
      })
      if (!result.success) {
        toast.error(result.message || t('Credential creation failed.'))
        return
      }

      const self = await getSelf()
      if (self.success && self.data) {
        setUser(self.data)
        toast.success(t('Developer access activated.'))
        const destination =
          Number(self.data.quota ?? 0) > 0 ? '/keys' : '/wallet'
        await navigate({ href: destination, replace: true })
        return
      }
      toast.error(t('Credential created. Refresh to continue.'))
    } catch {
      toast.error(t('Credential creation failed.'))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <SectionPageLayout>
      <SectionPageLayout.Title>{t('Developer access')}</SectionPageLayout.Title>
      <SectionPageLayout.Content>
        <div className='mx-auto grid max-w-5xl overflow-hidden border border-[#141413] bg-[#FAF9F5] text-[#141413] md:grid-cols-[1fr_0.8fr]'>
          <section className='bg-[#D97757] p-7 md:p-12'>
            <HugeiconsIcon
              icon={Key01Icon}
              className='mb-10 size-9'
              strokeWidth={2}
              aria-hidden='true'
            />
            <p className='mb-4 text-xs font-bold uppercase'>
              {t('One-time activation')}
            </p>
            <h1 className='mb-6 font-serif text-4xl leading-tight font-normal md:text-5xl'>
              {t('Create your first developer credential.')}
            </h1>
            <p className='max-w-xl text-sm leading-7'>
              {t(
                'Creating a credential permanently unlocks the developer console. You do not need to add funds first.'
              )}
            </p>
          </section>
          <section className='p-7 md:p-12'>
            <div className='mb-9 flex items-start gap-3 border-b border-[#141413]/30 pb-6'>
              <HugeiconsIcon
                icon={ShieldKeyIcon}
                className='mt-0.5 size-5 shrink-0'
                strokeWidth={2}
                aria-hidden='true'
              />
              <p className='text-sm leading-6'>
                {t(
                  'The credential is created with no expiry and no per-credential cap. You can change those controls later.'
                )}
              </p>
            </div>
            <div className='flex flex-col gap-3'>
              <Label htmlFor='credential-name'>{t('Credential name')}</Label>
              <Input
                id='credential-name'
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder={t('My first credential')}
                maxLength={30}
                autoComplete='off'
              />
            </div>
            <Button
              className='mt-7 w-full rounded-sm bg-[#141413] text-[#FAF9F5] hover:bg-[#141413]/85'
              disabled={!name.trim() || submitting}
              onClick={handleCreate}
            >
              {submitting && <Spinner data-icon='inline-start' />}
              {submitting ? t('Creating...') : t('Create credential')}
            </Button>
          </section>
        </div>
      </SectionPageLayout.Content>
    </SectionPageLayout>
  )
}
