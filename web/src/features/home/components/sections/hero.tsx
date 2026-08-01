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
import { normalizeInterfaceLanguage } from '@/i18n/languages'

import { HeroArt } from '../hero-art'

interface HeroProps {
  isAuthenticated?: boolean
}

const OUTLINE_CTA_CLASS =
  'border-[#141413]/35 bg-[#FAF9F5] text-[#141413] hover:border-[#141413] hover:bg-[#E3DACC] hover:text-[#141413] dark:border-[#141413]/35 dark:bg-[#FAF9F5] dark:text-[#141413] dark:hover:border-[#141413] dark:hover:bg-[#E3DACC] dark:hover:text-[#141413]'

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
        size='lg'
        className={OUTLINE_CTA_CLASS}
        render={<a href={href} target='_blank' rel='noopener noreferrer' />}
      >
        {content}
      </Button>
    )
  }

  return (
    <Button
      variant='outline'
      size='lg'
      className={OUTLINE_CTA_CLASS}
      render={<Link to={href} />}
    >
      {content}
    </Button>
  )
}

export function Hero({ isAuthenticated = false }: HeroProps) {
  const { t, i18n } = useTranslation()
  const { status } = useStatus()
  const docsLangByInterfaceLanguage: Record<string, 'en' | 'ja' | 'zh'> = {
    en: 'en',
    fr: 'en',
    ru: 'en',
    vi: 'en',
    ja: 'ja',
    zhCN: 'zh',
    zhTW: 'zh',
  }
  const docsLang =
    docsLangByInterfaceLanguage[
      normalizeInterfaceLanguage(i18n.resolvedLanguage || i18n.language)
    ]
  const docsUrl =
    (status?.docs_link as string | undefined) ||
    `https://docs.newapi.pro/${docsLang || 'en'}/docs`
  return (
    <section
      className='flex min-h-[calc(100svh-var(--app-header-height))] items-center overflow-hidden bg-[#FAF9F5] px-5 py-16 text-[#141413] sm:px-8 sm:py-24'
      aria-labelledby='home-hero-title'
    >
      <div className='mx-auto grid w-full max-w-6xl items-center gap-14 lg:grid-cols-[minmax(0,0.85fr)_minmax(25rem,1.15fr)] lg:gap-16 xl:gap-24'>
        <div className='max-w-2xl'>
          <div className='landing-animate-fade-up mb-7 flex items-center gap-3 opacity-0'>
            <span
              className='h-px w-9 shrink-0 bg-[#141413]'
              aria-hidden='true'
            />
            <p className='text-xs font-semibold tracking-[0.18em] uppercase'>
              {t('AI Application Infrastructure Foundation')}
            </p>
          </div>
          <h1
            id='home-hero-title'
            lang='en'
            className='landing-animate-fade-up max-w-[12ch] font-serif text-[clamp(3.25rem,7vw,5.75rem)] leading-[0.92] font-medium tracking-[-0.055em] text-balance opacity-0 [animation-delay:60ms]'
          >
            Token Not Included
          </h1>
          <p className='landing-animate-fade-up mt-8 max-w-[34rem] text-base leading-7 text-pretty text-[#141413]/70 opacity-0 [animation-delay:120ms] sm:text-lg'>
            {t(
              'Access a vast selection of models via a standard, unified API protocol. Power AI applications, manage digital assets, and connect the Future.'
            )}
          </p>

          <div className='landing-animate-fade-up mt-10 flex flex-col gap-3 opacity-0 [animation-delay:180ms] min-[420px]:flex-row min-[420px]:flex-wrap'>
            <Button
              size='lg'
              className='w-full border-[#141413] bg-[#141413] text-[#FAF9F5] hover:bg-[#D97757] hover:text-[#141413] min-[420px]:w-auto'
              render={<Link to={isAuthenticated ? '/dashboard' : '/sign-up'} />}
            >
              {isAuthenticated ? t('Go to Dashboard') : t('Get Started')}
              <ArrowRight data-icon='inline-end' />
            </Button>
            {!isAuthenticated ? (
              <Button
                variant='outline'
                size='lg'
                className={`w-full min-[420px]:w-auto ${OUTLINE_CTA_CLASS}`}
                render={<Link to='/pricing' />}
              >
                {t('View Pricing')}
              </Button>
            ) : null}
            <div className='[&_[data-slot=button]]:w-full min-[420px]:[&_[data-slot=button]]:w-auto'>
              <DocsLink href={docsUrl} label={t('Docs')} />
            </div>
          </div>
        </div>

        <HeroArt caption={t('Configure upstream providers and routing.')} />
      </div>
    </section>
  )
}
