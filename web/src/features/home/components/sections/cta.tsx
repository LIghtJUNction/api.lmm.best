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
import { Link } from '@tanstack/react-router'
import { ArrowRight } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { AnimateInView } from '@/components/animate-in-view'
import { Button } from '@/components/ui/button'

interface CTAProps {
  isAuthenticated?: boolean
}

export function CTA({ isAuthenticated = false }: CTAProps) {
  const { t } = useTranslation()

  if (isAuthenticated) return null

  return (
    <section className='bg-[#BCD1CA] px-5 py-20 text-[#141413] sm:px-8 sm:py-28'>
      <AnimateInView className='mx-auto grid max-w-7xl gap-8 border-y-2 border-[#141413] py-10 md:grid-cols-[1fr_auto] md:items-end'>
        <div>
          <p className='mb-4 text-xs font-semibold tracking-[0.18em] uppercase'>
            {t('Open Source')}
          </p>
          <h2 className='max-w-[18ch] font-serif text-4xl leading-none font-medium tracking-[-0.04em] sm:text-6xl'>
            {t('Ready to simplify')} {t('your AI integration?')}
          </h2>
        </div>
        <Button
          className='w-fit border-[#141413] bg-[#141413] text-[#FAF9F5] hover:bg-[#FAF9F5] hover:text-[#141413]'
          render={<Link to='/sign-up' />}
        >
          {t('Get Started')}
          <ArrowRight data-icon='inline-end' />
        </Button>
      </AnimateInView>
    </section>
  )
}
