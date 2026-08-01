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
import { BarChart3, Route, Unplug } from 'lucide-react'
import { useTranslation } from 'react-i18next'

const STEPS = [
  {
    number: '1',
    title: 'Connect',
    description:
      'Add your API keys, set up channels and configure access permissions',
    icon: Unplug,
  },
  {
    number: '2',
    title: 'Configure routes',
    description:
      'Connect through OpenAI, Claude, Gemini, and other compatible API routes',
    icon: Route,
  },
  {
    number: '3',
    title: 'Monitor',
    description: 'Track usage, costs and performance with real-time analytics',
    icon: BarChart3,
  },
] as const

export function HowItWorks() {
  const { t } = useTranslation()

  return (
    <section
      data-home-onboarding
      aria-labelledby='home-onboarding-title'
      className='bg-[#F0EEE6] px-5 py-12 text-[#141413] sm:px-8 sm:py-14 md:py-16 dark:bg-[#141413] dark:text-[#FAF9F5]'
    >
      <div className='mx-auto max-w-7xl border-y-2 border-[#141413] py-8 sm:py-10 dark:border-[#FAF9F5]'>
        <header className='mb-8 grid gap-3 md:mb-10 md:grid-cols-[15rem_minmax(0,1fr)] md:items-end'>
          <p className='text-xs font-semibold tracking-[0.18em] uppercase'>
            {t('How It Works')}
          </p>
          <h2
            id='home-onboarding-title'
            className='max-w-[18ch] font-serif text-3xl leading-[0.95] font-medium tracking-[-0.04em] text-balance sm:text-4xl lg:text-5xl'
          >
            {t('Three steps to get started')}
          </h2>
        </header>

        <ol className='grid border-t-2 border-[#141413] md:grid-cols-3 dark:border-[#FAF9F5]'>
          {STEPS.map((step, index) => {
            const Icon = step.icon
            return (
              <li
                key={step.number}
                className='relative grid gap-5 border-b border-[#141413]/30 py-6 last:border-b-0 md:border-r md:border-b-0 md:px-6 md:first:pl-0 md:last:border-r-0 md:last:pr-0 dark:border-[#FAF9F5]/30'
              >
                <div className='flex items-start justify-between gap-4'>
                  <span className='font-mono text-xs tracking-[0.16em]'>
                    0{step.number}
                  </span>
                  <span
                    className='flex size-11 rotate-[-2deg] items-center justify-center [border-radius:45%_55%_48%_52%/56%_43%_57%_44%] border-2 border-[#141413] bg-[#BCD1CA] text-[#141413] odd:rotate-[2deg]'
                    aria-hidden='true'
                  >
                    <Icon className='size-6' strokeWidth={1.8} />
                  </span>
                </div>
                <div className='self-end'>
                  <h3 className='font-serif text-2xl leading-tight font-medium'>
                    {t(step.title)}
                  </h3>
                  <p className='mt-2 max-w-sm text-sm leading-6 text-[#141413]/68 dark:text-[#FAF9F5]/68'>
                    {t(step.description)}
                  </p>
                </div>
                {index < STEPS.length - 1 ? (
                  <span
                    className='absolute right-[-0.45rem] bottom-[-0.36rem] hidden size-3 rounded-full bg-[#141413] md:block dark:bg-[#FAF9F5]'
                    aria-hidden='true'
                  />
                ) : null}
              </li>
            )
          })}
        </ol>
      </div>
    </section>
  )
}
