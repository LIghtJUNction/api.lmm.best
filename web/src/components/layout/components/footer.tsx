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
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'

import { BrandLogo } from '@/components/brand-logo'
import { LMM_BRAND_NAME } from '@/components/lmm-brand-mark'
import { useSystemConfig } from '@/hooks/use-system-config'
import { normalizeInterfaceLanguage } from '@/i18n/languages'
import { DEFAULT_LOGO, DEFAULT_SYSTEM_NAME } from '@/lib/constants'
import { cn } from '@/lib/utils'

interface FooterLink {
  text: string
  href: string
}

interface FooterColumnProps {
  title: string
  links: FooterLink[]
}

interface FooterProps {
  logo?: string
  name?: string
  columns?: FooterColumnProps[]
  copyright?: string
  className?: string
}

const NEW_API_FOOTER_ATTRIBUTION_KEY = [
  'footer',
  'new' + 'api',
  'projectAttributionSuffix',
].join('.')

const docsLanguageByInterfaceLanguage: Record<string, 'en' | 'ja' | 'zh'> = {
  en: 'en',
  fr: 'en',
  ja: 'ja',
  ru: 'en',
  vi: 'en',
  zhCN: 'zh',
  zhTW: 'zh',
}

function FooterLinkItem(props: { link: FooterLink }) {
  const { t } = useTranslation()
  const isExternal = props.link.href.startsWith('http')
  const label = t(props.link.text)

  if (isExternal) {
    return (
      <a
        href={props.link.href}
        target='_blank'
        rel='noopener noreferrer'
        className='text-muted-foreground hover:text-foreground text-sm transition-colors duration-200'
      >
        {label}
      </a>
    )
  }

  return (
    <Link
      to={props.link.href}
      className='text-muted-foreground hover:text-foreground text-sm transition-colors duration-200'
    >
      {label}
    </Link>
  )
}

function ComplianceLinks() {
  const { t } = useTranslation()
  const items: { key: string; label: string; href: string }[] = [
    {
      key: 'user-agreement',
      label: t('Terms of Service'),
      href: '/user-agreement',
    },
    {
      key: 'privacy-policy',
      label: t('Privacy Policy'),
      href: '/privacy-policy',
    },
    {
      key: 'pricing',
      label: t('Pricing'),
      href: '/pricing',
    },
  ]
  return (
    <div className='flex w-full flex-wrap items-center justify-center gap-x-5 gap-y-2 border-y border-[#141413]/25 py-3 text-sm text-[#141413]/75 sm:justify-start dark:border-[#FAF9F5]/25 dark:text-[#FAF9F5]/75'>
      {items.map((item) => (
        <Link
          key={item.key}
          to={item.href}
          className='hover:text-foreground font-medium transition-colors duration-200'
        >
          {item.label}
        </Link>
      ))}
      <a
        href='mailto:lightjunction.me@gmail.com'
        className='hover:text-foreground font-medium transition-colors duration-200'
      >
        {t('Customer Support')}: lightjunction.me@gmail.com
      </a>
    </div>
  )
}

// inline=true returns just the inner span for composition in a parent flex
// row. inline=false wraps in a centered/right-aligned div (default).
function ProjectAttribution(props: { currentYear: number; inline?: boolean }) {
  const { t } = useTranslation()
  const content = (
    <span className='text-muted-foreground/45'>
      &copy; {props.currentYear}{' '}
      <a
        href='https://github.com/QuantumNous/new-api'
        target='_blank'
        rel='noopener noreferrer'
        className='text-foreground/70 hover:text-foreground font-medium transition-colors'
      >
        {t('New API')}
      </a>
      . {t(NEW_API_FOOTER_ATTRIBUTION_KEY)}
    </span>
  )
  if (props.inline) {
    return content
  }
  return (
    <div className='text-muted-foreground/45 text-center text-xs sm:text-right'>
      {content}
    </div>
  )
}

export function Footer(props: FooterProps) {
  const { t, i18n } = useTranslation()
  const {
    systemName,
    logo: systemLogo,
    footerHtml,
    demoSiteEnabled,
  } = useSystemConfig()
  const docsLang =
    docsLanguageByInterfaceLanguage[
      normalizeInterfaceLanguage(i18n.resolvedLanguage || i18n.language)
    ]
  const docsBaseUrl = `https://docs.newapi.pro/${docsLang || 'en'}/docs`

  const displayLogo = systemLogo || props.logo || DEFAULT_LOGO
  const configuredName = systemName || props.name || DEFAULT_SYSTEM_NAME
  const usesDefaultBrand = displayLogo === DEFAULT_LOGO
  const displayName =
    usesDefaultBrand && configuredName === DEFAULT_SYSTEM_NAME
      ? LMM_BRAND_NAME
      : configuredName
  const isDemoSiteMode = Boolean(demoSiteEnabled)
  const currentYear = new Date().getFullYear()

  const fallbackColumns = useMemo<FooterColumnProps[]>(
    () => [
      {
        title: t('footer.columns.about.title'),
        links: [
          {
            text: t('footer.columns.about.links.aboutProject'),
            href: `${docsBaseUrl}/guide/wiki/basic-concepts/project-introduction`,
          },
          {
            text: t('footer.columns.about.links.contact'),
            href: `${docsBaseUrl}/support/community-interaction`,
          },
          {
            text: t('footer.columns.about.links.features'),
            href: `${docsBaseUrl}/guide/wiki/basic-concepts/features-introduction`,
          },
        ],
      },
      {
        title: t('footer.columns.docs.title'),
        links: [
          {
            text: t('footer.columns.docs.links.quickStart'),
            href: `${docsBaseUrl}/guide/home`,
          },
          {
            text: t('footer.columns.docs.links.installation'),
            href: `${docsBaseUrl}/installation`,
          },
          {
            text: t('footer.columns.docs.links.apiDocs'),
            href: `${docsBaseUrl}/api`,
          },
        ],
      },
      {
        title: t('footer.columns.related.title'),
        links: [
          {
            text: t('footer.columns.related.links.oneApi'),
            href: 'https://github.com/songquanpeng/one-api',
          },
          {
            text: t('footer.columns.related.links.midjourney'),
            href: 'https://github.com/novicezk/midjourney-proxy',
          },
          {
            text: t('footer.columns.related.links.newApiKeyTool'),
            href: 'https://github.com/Calcium-Ion/new-api-key-tool',
          },
        ],
      },
    ],
    [t, docsBaseUrl]
  )

  const displayColumns = props.columns ?? fallbackColumns

  if (footerHtml) {
    return (
      <footer
        className={cn(
          'relative z-10 border-t-2 border-[#141413] bg-[#FAF9F5] text-[#141413] dark:border-[#FAF9F5] dark:bg-[#141413] dark:text-[#FAF9F5]',
          props.className
        )}
      >
        <div className='mx-auto w-full max-w-7xl px-5 py-6 sm:px-8'>
          <div className='flex flex-col gap-4'>
            <div className='flex flex-col items-center justify-between gap-3 sm:flex-row'>
              <div
                className='custom-footer text-muted-foreground min-w-0 text-center text-sm sm:text-left'
                dangerouslySetInnerHTML={{ __html: footerHtml }}
              />
              <ProjectAttribution currentYear={currentYear} inline />
            </div>
            <ComplianceLinks />
          </div>
        </div>
      </footer>
    )
  }

  return (
    <footer
      className={cn(
        'relative z-10 border-t-2 border-[#141413] bg-[#FAF9F5] text-[#141413] dark:border-[#FAF9F5] dark:bg-[#141413] dark:text-[#FAF9F5]',
        props.className
      )}
    >
      <div className='mx-auto max-w-7xl px-5 py-7 sm:px-8 md:py-8'>
        <div
          className='mb-6 h-[3px] w-20 rotate-[-1deg] rounded-full bg-[#BCD1CA]'
          aria-hidden='true'
        />
        <div className='flex flex-col justify-between gap-6 md:flex-row md:gap-16'>
          {/* Brand column */}
          <div className='shrink-0'>
            <Link to='/' className='group flex items-center gap-2.5'>
              <BrandLogo src={displayLogo} className='size-9 object-contain' />
              <span className='text-base font-semibold tracking-[-0.025em]'>
                {displayName}
              </span>
            </Link>
            <p className='mt-3 max-w-[15rem] text-xs leading-relaxed text-[#141413]/58 dark:text-[#FAF9F5]/58'>
              {t('Powerful API Management Platform')}
            </p>
          </div>

          {/* Links columns */}
          {isDemoSiteMode && (
            <div className='grid grid-cols-3 gap-8 md:gap-16'>
              {displayColumns.map((column) => (
                <div key={column.title}>
                  <p className='text-muted-foreground/50 mb-3 text-xs font-medium tracking-wider uppercase'>
                    {t(column.title)}
                  </p>
                  <ul className='space-y-2.5'>
                    {column.links.map((link) => (
                      <li key={`${link.href}:${link.text}`}>
                        <FooterLinkItem link={link} />
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className='mt-6'>
          <ComplianceLinks />
        </div>

        {/* Copyright and project attribution; wraps on narrow screens. */}
        <div className='mt-6 flex flex-col items-center justify-between gap-x-3 gap-y-2 border-t border-[#141413]/25 pt-4 sm:flex-row dark:border-[#FAF9F5]/25'>
          <div className='text-muted-foreground/40 flex flex-wrap items-center justify-center gap-x-2 gap-y-1 text-xs sm:justify-start'>
            <span>
              &copy; {currentYear} {displayName}.{' '}
              {props.copyright ?? t('footer.defaultCopyright')}
            </span>
          </div>
          <ProjectAttribution currentYear={currentYear} />
        </div>
      </div>
    </footer>
  )
}
