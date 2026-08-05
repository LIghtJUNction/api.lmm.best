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

import { HeroArt } from '../hero-art'

interface HeroProps {
  isAuthenticated?: boolean
}

const OUTLINE_CTA_CLASS =
  'border-[#141413]/45 bg-transparent text-[#141413] hover:border-[#141413] hover:bg-[#BCD1CA] hover:text-[#141413] dark:border-[#FAF9F5]/45 dark:text-[#FAF9F5] dark:hover:border-[#FAF9F5] dark:hover:bg-[#BCD1CA] dark:hover:text-[#141413]'

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
  const { t } = useTranslation()
  const { status } = useStatus()
  const docsUrl =
    (status?.docs_link as string | undefined) ||
    'https://github.com/LIghtJUNction/api.lmm.best#readme'
  return (
    <section
      className='relative overflow-hidden bg-[#FAF9F5] px-5 pt-28 pb-14 text-[#141413] sm:px-8 sm:pt-32 sm:pb-20 lg:pt-36 lg:pb-24 dark:bg-[#141413] dark:text-[#FAF9F5]'
      aria-labelledby='home-hero-title'
    >
      <div className='mx-auto grid w-full max-w-7xl items-center gap-14 lg:grid-cols-[minmax(0,1.15fr)_minmax(24rem,0.85fr)] lg:gap-12 xl:gap-20'>
        <div className='max-w-[46rem]'>
          <div className='landing-animate-fade-up mb-6 flex items-center gap-3 opacity-0 sm:mb-8'>
            <span
              className='h-px w-9 shrink-0 bg-[#141413]'
              aria-hidden='true'
            />
            <p className='text-[0.6875rem] font-semibold tracking-[0.2em] uppercase dark:text-[#FAF9F5]'>
              {t('AI Application Infrastructure Foundation')}
            </p>
          </div>
          <h1
            id='home-hero-title'
            lang='en'
            className='landing-animate-fade-up font-serif text-[clamp(3.3rem,7vw,7rem)] leading-[0.84] font-medium tracking-[-0.065em] opacity-0 [animation-delay:60ms]'
          >
            <span className='block whitespace-nowrap'>Token Not</span>
            <span className='block whitespace-nowrap'>
              Included<span className='text-[#6F9589]'>.</span>
            </span>
          </h1>
          <p
            lang='zh-CN'
            className='landing-animate-fade-up mt-7 max-w-[38rem] border-l-2 border-[#141413] pl-5 text-base leading-7 text-pretty text-[#141413]/72 opacity-0 [animation-delay:120ms] sm:mt-9 sm:text-lg dark:border-[#FAF9F5] dark:text-[#FAF9F5]/72'
          >
            尊重开源，支持开源，拥抱开源
          </p>

          <div className='landing-animate-fade-up mt-8 flex flex-col gap-3 opacity-0 [animation-delay:180ms] min-[420px]:flex-row min-[420px]:flex-wrap sm:mt-10'>
            <Button
              size='lg'
              className='w-full border-[#141413] bg-[#141413] text-[#FAF9F5] hover:bg-[#BCD1CA] hover:text-[#141413] min-[420px]:w-auto dark:border-[#FAF9F5] dark:bg-[#FAF9F5] dark:text-[#141413] dark:hover:bg-[#BCD1CA]'
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
