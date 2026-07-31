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
import { ArrowRight, BookOpen } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { useStatus } from '@/hooks/use-status'

interface HeroProps {
  isAuthenticated?: boolean
}

function DocsLink({ href, label }: { href: string; label: string }) {
  const isExternal = /^https?:\/\//i.test(href)
  const content = (
    <>
      <BookOpen data-icon='inline-start' />
      {label}
    </>
  )

  if (isExternal) {
    return (
      <Button
        variant='outline'
        render={<a href={href} target='_blank' rel='noopener noreferrer' />}
      >
        {content}
      </Button>
    )
  }

  return (
    <Button variant='outline' render={<Link to={href} />}>
      {content}
    </Button>
  )
}

export function Hero({ isAuthenticated = false }: HeroProps) {
  const { t } = useTranslation()
  const { status } = useStatus()
  const docsUrl =
    (status?.docs_link as string | undefined) || 'https://docs.newapi.pro'

  return (
    <section className='overflow-hidden bg-[#FAF9F5] px-5 pt-20 pb-16 text-[#141413] sm:px-8 sm:pt-28 sm:pb-24'>
      <div className='mx-auto grid max-w-6xl items-center gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(22rem,0.82fr)] lg:gap-16'>
        <div className='max-w-2xl'>
          <p className='landing-animate-fade-up mb-6 text-xs font-semibold tracking-[0.18em] uppercase opacity-0'>
            {t('AI Application Infrastructure Foundation')}
          </p>
          <h1 className='landing-animate-fade-up max-w-[13ch] font-serif text-[clamp(3rem,7vw,5.75rem)] leading-[0.94] font-medium tracking-[-0.055em] opacity-0 [animation-delay:60ms]'>
            {t('Unified API Gateway for')} {t('Vast Range of AI Models')}
          </h1>
          <p className='landing-animate-fade-up mt-7 max-w-xl text-base leading-7 text-[#141413]/70 opacity-0 [animation-delay:120ms] sm:text-lg'>
            {t(
              'Access a vast selection of models via a standard, unified API protocol. Power AI applications, manage digital assets, and connect the Future.'
            )}
          </p>

          <div className='landing-animate-fade-up mt-9 flex flex-wrap gap-3 opacity-0 [animation-delay:180ms]'>
            <Button
              className='border-[#141413] bg-[#141413] text-[#FAF9F5] hover:bg-[#D97757] hover:text-[#141413]'
              render={<Link to={isAuthenticated ? '/dashboard' : '/sign-up'} />}
            >
              {isAuthenticated ? t('Go to Dashboard') : t('Get Started')}
              <ArrowRight data-icon='inline-end' />
            </Button>
            {!isAuthenticated ? (
              <Button
                variant='outline'
                className='border-[#141413]/30 bg-transparent hover:bg-[#E3DACC]'
                render={<Link to='/pricing' />}
              >
                {t('View Pricing')}
              </Button>
            ) : null}
            <DocsLink href={docsUrl} label={t('Docs')} />
          </div>
        </div>

        <figure className='landing-animate-fade-up relative mx-auto w-full max-w-xl opacity-0 [animation-delay:240ms]'>
          <div
            aria-hidden
            className='absolute -inset-4 rotate-2 rounded-[38%_62%_48%_52%/54%_42%_58%_46%] bg-[#D97757] sm:-inset-6'
          />
          <div className='relative -rotate-1 overflow-hidden rounded-[52%_48%_60%_40%/43%_58%_42%_57%] border-2 border-[#141413] bg-[#BCD1CA]'>
            <img
              src='/logo.png'
              width='512'
              height='512'
              alt=''
              className='aspect-square size-full object-cover'
              decoding='async'
              fetchPriority='high'
            />
          </div>
          <figcaption className='sr-only'>
            {t('Configure upstream providers and routing.')}
          </figcaption>
        </figure>
      </div>
    </section>
  )
}
