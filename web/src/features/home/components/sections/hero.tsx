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

import { HeaderLogo } from '@/components/layout/components/header-logo'
import { Button } from '@/components/ui/button'
import { useStatus } from '@/hooks/use-status'
import { toIntlLocale } from '@/i18n/languages'
import { cn } from '@/lib/utils'

import { isCjkLocale } from '../../lib/cjk-locale'

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
  const { t, i18n } = useTranslation()
  const { status } = useStatus()
  const docsUrl =
    (status?.docs_link as string | undefined) || 'https://docs.newapi.pro'
  const language = i18n.resolvedLanguage || i18n.language
  const isCjk = isCjkLocale(language)
  const documentLanguage = toIntlLocale(language)

  return (
    <section className='overflow-hidden bg-[#FAF9F5] px-5 pt-20 pb-16 text-[#141413] sm:px-8 sm:pt-28 sm:pb-24'>
      <div className='mx-auto grid max-w-6xl items-center gap-14 lg:grid-cols-[minmax(0,1fr)_minmax(20rem,0.7fr)] lg:gap-20'>
        <div className='max-w-2xl'>
          <p className='landing-animate-fade-up mb-6 text-xs font-semibold tracking-[0.18em] uppercase opacity-0'>
            {t('AI Application Infrastructure Foundation')}
          </p>
          <h1
            lang={documentLanguage}
            className={cn(
              'landing-animate-fade-up font-serif font-medium opacity-0 [animation-delay:60ms]',
              isCjk
                ? 'max-w-[11em] text-[clamp(2.5rem,5.2vw,4.25rem)] leading-[1.08] tracking-[-0.035em] [overflow-wrap:normal] [word-break:normal]'
                : 'max-w-[13ch] text-[clamp(3rem,7vw,5.75rem)] leading-[0.94] tracking-[-0.055em]'
            )}
          >
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

        <figure className='landing-animate-fade-up mx-auto w-full max-w-md border-2 border-[#141413] bg-[#D97757] p-5 opacity-0 [animation-delay:240ms] sm:p-7 lg:mr-8 lg:max-w-sm lg:-translate-y-3 lg:justify-self-end lg:rounded-[42%_58%_45%_55%/8%_12%_88%_92%]'>
          <div className='ml-auto w-[82%] overflow-hidden rounded-[52%_48%_60%_40%/43%_58%_42%_57%] border-2 border-[#141413] bg-[#BCD1CA]'>
            <HeaderLogo
              src='/logo.png'
              width={512}
              height={512}
              alt=''
              loading={false}
              logoLoaded
              className='aspect-square size-full rounded-none object-cover transition-none'
              decoding='async'
              fetchPriority='high'
            />
          </div>
          <figcaption className='mt-5 max-w-64 border-t border-[#141413] pt-3 text-xs leading-5 font-medium'>
            {t('Configure upstream providers and routing.')}
          </figcaption>
        </figure>
      </div>
    </section>
  )
}
