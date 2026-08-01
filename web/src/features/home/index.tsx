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
import { useCallback, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'

import { PublicLayout } from '@/components/layout'
import { RichContent } from '@/components/rich-content'
import { Skeleton } from '@/components/ui/skeleton'
import { useTheme } from '@/context/theme-provider'
import { isLikelyHtml } from '@/lib/content-format'
import { useAuthStore } from '@/stores/auth-store'

import { CTA, Features, Hero, HowItWorks, Stats } from './components'
import { HeroArtSkeleton } from './components/hero-art'
import { useHomePageContent } from './hooks'

export function Home() {
  const { i18n, t } = useTranslation()
  const iframeRef = useRef<HTMLIFrameElement>(null)
  const { resolvedTheme } = useTheme()
  const isAuthenticated = useAuthStore((state) => Boolean(state.auth.user))
  const { content, isLoaded, isUrl } = useHomePageContent()

  const syncIframePreferences = useCallback(() => {
    if (!isUrl || !iframeRef.current?.contentWindow) return

    // Without allow-same-origin the sandbox has an opaque origin, so a concrete
    // target cannot match. Keep the message payload limited to display preferences.
    iframeRef.current.contentWindow.postMessage(
      { themeMode: resolvedTheme },
      '*'
    )
    iframeRef.current.contentWindow.postMessage({ lang: i18n.language }, '*')
  }, [i18n.language, isUrl, resolvedTheme])

  useEffect(() => {
    if (isUrl) {
      syncIframePreferences()
    }
  }, [isUrl, syncIframePreferences])

  if (!isLoaded) {
    return (
      <PublicLayout showMainContainer={false}>
        <main
          className='flex min-h-[calc(100svh-var(--app-header-height))] items-center bg-[#FAF9F5] px-5 py-16 sm:px-8 sm:py-24'
          aria-busy='true'
          aria-live='polite'
        >
          <span className='sr-only'>{t('Loading...')}</span>
          <div className='mx-auto grid w-full max-w-6xl items-center gap-14 lg:grid-cols-[minmax(0,0.85fr)_minmax(25rem,1.15fr)] lg:gap-16 xl:gap-24'>
            <div className='max-w-2xl'>
              <Skeleton className='mb-7 h-3 w-56 bg-[#141413]/10' />
              <Skeleton className='h-28 w-full max-w-lg rounded-3xl bg-[#141413]/10 sm:h-40' />
              <div className='mt-8 flex flex-col gap-3'>
                <Skeleton className='h-4 w-full max-w-xl bg-[#141413]/10' />
                <Skeleton className='h-4 w-4/5 max-w-lg bg-[#141413]/10' />
              </div>
              <div className='mt-10 flex flex-col gap-3 min-[420px]:flex-row min-[420px]:flex-wrap'>
                <Skeleton className='h-9 w-full bg-[#141413]/10 min-[420px]:w-32' />
                {!isAuthenticated ? (
                  <Skeleton className='h-9 w-full bg-[#141413]/10 min-[420px]:w-24' />
                ) : null}
                <Skeleton className='h-9 w-full bg-[#141413]/10 min-[420px]:w-20' />
              </div>
            </div>
            <HeroArtSkeleton />
          </div>
        </main>
      </PublicLayout>
    )
  }

  if (content) {
    if (isUrl) {
      return (
        <PublicLayout showMainContainer={false}>
          {/*
            allow-top-navigation-by-user-activation: the custom home page URL is
            admin-configured (trusted); this lets its target="_top" nav/menu links
            navigate the top-level window on user click. The default sandbox blocks
            this on desktop, while some mobile browsers allow it via allow-popups,
            causing inconsistent behavior. This token only permits user-activated
            top-level navigation and does NOT grant same-origin access.
          */}
          <iframe
            ref={iframeRef}
            src={content}
            className='h-screen w-full border-none'
            title={t('Custom Home Page')}
            sandbox='allow-forms allow-popups allow-popups-to-escape-sandbox allow-scripts allow-top-navigation-by-user-activation'
            onLoad={syncIframePreferences}
          />
        </PublicLayout>
      )
    }

    const contentIsHtml = isLikelyHtml(content)

    if (contentIsHtml) {
      return (
        <PublicLayout showMainContainer={false}>
          <RichContent
            mode='html'
            htmlVariant='isolated'
            content={content}
            className='custom-home-content'
          />
        </PublicLayout>
      )
    }

    return (
      <PublicLayout>
        <div className='mx-auto max-w-6xl px-4 py-8'>
          <RichContent
            mode='markdown'
            content={content}
            className='custom-home-content'
          />
        </div>
      </PublicLayout>
    )
  }

  return (
    <PublicLayout showMainContainer={false}>
      <Hero isAuthenticated={isAuthenticated} />
      <Stats />
      <Features />
      <HowItWorks />
      <CTA isAuthenticated={isAuthenticated} />
    </PublicLayout>
  )
}
