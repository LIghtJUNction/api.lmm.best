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
import { BarChart3, Route, Waypoints } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { AnimateInView } from '@/components/animate-in-view'

const FEATURES = [
  {
    number: '01',
    title: 'Multi-protocol Compatible',
    description: 'Compatible API routes for common AI application workflows',
    icon: Waypoints,
  },
  {
    number: '02',
    title: 'Load Balancing',
    description: 'Configure routes',
    icon: Route,
  },
  {
    number: '03',
    title: 'Transparent Billing',
    description: 'Track usage, costs and performance with real-time analytics',
    icon: BarChart3,
  },
] as const

export function Features() {
  const { t } = useTranslation()

  return (
    <section className='bg-[#FAF9F5] px-5 py-20 text-[#141413] sm:px-8 sm:py-28'>
      <div className='mx-auto max-w-6xl'>
        <AnimateInView className='mb-12 grid gap-5 border-t-2 border-[#141413] pt-6 md:grid-cols-2'>
          <p className='text-xs font-semibold tracking-[0.18em] uppercase'>
            {t('Core Features')}
          </p>
          <h2 className='max-w-[18ch] font-serif text-4xl leading-none font-medium tracking-[-0.04em] sm:text-5xl'>
            {t('Built for developers,')} {t('designed for scale')}
          </h2>
        </AnimateInView>

        <div className='grid border-y-2 border-[#141413] md:grid-cols-3'>
          {FEATURES.map((feature, index) => {
            const Icon = feature.icon
            return (
              <AnimateInView
                key={feature.number}
                delay={index * 90}
                className='group flex min-h-72 flex-col gap-8 border-b border-[#141413]/30 py-8 last:border-b-0 md:border-r md:border-b-0 md:px-8 md:first:pl-0 md:last:border-r-0 md:last:pr-0'
              >
                <div className='flex items-center justify-between'>
                  <span className='font-mono text-xs'>{feature.number}</span>
                  <Icon
                    className='size-8'
                    aria-hidden='true'
                    strokeWidth={1.5}
                  />
                </div>
                <div className='mt-auto'>
                  <h3 className='font-serif text-2xl font-medium'>
                    {t(feature.title)}
                  </h3>
                  <p className='mt-3 max-w-sm text-sm leading-6 text-[#141413]/65'>
                    {t(feature.description)}
                  </p>
                </div>
              </AnimateInView>
            )
          })}
        </div>
      </div>
    </section>
  )
}
