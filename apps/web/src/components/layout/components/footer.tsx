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
import { Link, useRouterState } from '@tanstack/react-router'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'

import { BrandLogo } from '@/components/brand-logo'
import { LMM_BRAND_NAME, LmmBrandMark } from '@/components/lmm-brand-mark'
import { useSystemConfig } from '@/hooks/use-system-config'
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
    <div className='w-full border-y border-[#141413]/25 py-3 text-sm text-[#141413]/75 dark:border-[#FAF9F5]/25 dark:text-[#FAF9F5]/75'>
      <div className='flex flex-wrap items-center justify-center gap-x-5 gap-y-2 sm:justify-start'>
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
          href='mailto:support@lmm.best'
          className='hover:text-foreground font-medium transition-colors duration-200'
        >
          {t('Customer Support')}: support@lmm.best
        </a>
      </div>
    </div>
  )
}

// inline=true returns just the inner span for composition in a parent flex
// row. inline=false wraps in a centered/right-aligned div (default).
function ProjectAttribution(props: {
  currentYear: number
  name: string
  inline?: boolean
}) {
  const { t } = useTranslation()
  const content = (
    <span className='text-muted-foreground/45'>
      &copy; {props.currentYear} {props.name}.{' '}
      {t('Open-source bounty collaboration')}
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
  const { t } = useTranslation()
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  })
  const {
    systemName,
    logo: systemLogo,
    footerHtml,
    demoSiteEnabled,
  } = useSystemConfig()
  const isForgeSurface =
    pathname === '/' ||
    pathname.startsWith('/challenges') ||
    pathname.startsWith('/pricing') ||
    pathname.startsWith('/rankings') ||
    pathname.startsWith('/about') ||
    pathname.startsWith('/user-agreement') ||
    pathname.startsWith('/privacy-policy') ||
    pathname.startsWith('/terms') ||
    pathname.startsWith('/sign-in') ||
    pathname.startsWith('/sign-up') ||
    pathname.startsWith('/signup') ||
    pathname.startsWith('/register') ||
    pathname.startsWith('/forgot-password') ||
    pathname.startsWith('/reset') ||
    pathname.startsWith('/otp') ||
    pathname.startsWith('/oauth')
  const displayLogo = systemLogo || props.logo || DEFAULT_LOGO
  const configuredName = systemName || props.name || DEFAULT_SYSTEM_NAME
  const usesDefaultBrand = displayLogo === DEFAULT_LOGO
  const displayName =
    isForgeSurface ||
    (usesDefaultBrand && configuredName === DEFAULT_SYSTEM_NAME)
      ? LMM_BRAND_NAME
      : configuredName
  const isDemoSiteMode = Boolean(demoSiteEnabled)
  const currentYear = new Date().getFullYear()

  const fallbackColumns = useMemo<FooterColumnProps[]>(
    () => [
      {
        title: t('Challenges'),
        links: [
          {
            text: t('Browse challenges'),
            href: '/challenges',
          },
          {
            text: t('Open work'),
            href: '/challenges',
          },
          {
            text: t('How it works'),
            href: '/#workflow',
          },
        ],
      },
      {
        title: t('Terms'),
        links: [
          {
            text: t('Terms'),
            href: '/user-agreement',
          },
          {
            text: t('Privacy'),
            href: '/privacy-policy',
          },
          {
            text: t('Open-source attribution'),
            href: '/about',
          },
        ],
      },
    ],
    [t]
  )

  const displayColumns = props.columns ?? fallbackColumns

  if (footerHtml && !isForgeSurface) {
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
              <ProjectAttribution
                currentYear={currentYear}
                name={displayName}
                inline
              />
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
              {isForgeSurface ? (
                <LmmBrandMark className='size-9' title={LMM_BRAND_NAME} />
              ) : (
                <BrandLogo
                  src={displayLogo}
                  className='size-9 object-contain'
                />
              )}
              <span className='text-base font-semibold tracking-[-0.025em]'>
                {displayName}
              </span>
            </Link>
            <p className='mt-3 max-w-[15rem] text-xs leading-relaxed text-[#141413]/58 dark:text-[#FAF9F5]/58'>
              {t('Open-source bounty collaboration')}
            </p>
          </div>

          {/* Links columns */}
          {isDemoSiteMode && (
            <div className='grid grid-cols-2 gap-8 md:gap-16'>
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
          <ProjectAttribution currentYear={currentYear} name={displayName} />
        </div>
      </div>
    </footer>
  )
}
