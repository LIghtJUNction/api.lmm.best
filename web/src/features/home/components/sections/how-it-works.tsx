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

import { AnimateInView } from '@/components/animate-in-view'

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
    <section className='bg-[#F0EEE6] px-5 py-20 text-[#141413] sm:px-8 sm:py-28 dark:bg-[#22221F] dark:text-[#FAF9F5]'>
      <div className='mx-auto max-w-7xl'>
        <AnimateInView className='mb-14 max-w-2xl'>
          <p className='mb-4 text-xs font-semibold tracking-[0.18em] uppercase'>
            {t('How It Works')}
          </p>
          <h2 className='font-serif text-4xl leading-none font-medium tracking-[-0.04em] sm:text-5xl'>
            {t('Three steps to get started')}
          </h2>
        </AnimateInView>

        <ol className='grid gap-10 md:grid-cols-3'>
          {STEPS.map((step, index) => {
            const Icon = step.icon
            return (
              <AnimateInView
                key={step.number}
                delay={index * 100}
                as='li'
                className='relative border-t-2 border-[#141413] pt-6 dark:border-[#FAF9F5]'
              >
                <div className='mb-12 flex items-center justify-between'>
                  <span className='font-mono text-sm'>0{step.number}</span>
                  <Icon
                    className='size-7'
                    aria-hidden='true'
                    strokeWidth={1.5}
                  />
                </div>
                <h3 className='font-serif text-2xl font-medium'>
                  {t(step.title)}
                </h3>
                <p className='mt-3 text-sm leading-6 text-[#141413]/65 dark:text-[#FAF9F5]/65'>
                  {t(step.description)}
                </p>
              </AnimateInView>
            )
          })}
        </ol>
      </div>
    </section>
  )
}
