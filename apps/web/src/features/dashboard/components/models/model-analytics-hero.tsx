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
import { Analytics01Icon } from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useTranslation } from 'react-i18next'

import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'

/** A compact visual anchor for the model-analytics workspace. */
export function ModelAnalyticsHero() {
  const { t } = useTranslation()

  return (
    <Card className='py-0'>
      <div className='grid min-h-40 grid-cols-1 md:grid-cols-[minmax(0,1fr)_minmax(18rem,0.72fr)]'>
        <CardHeader className='self-center px-4 py-5 sm:px-6'>
          <div className='flex flex-wrap items-center gap-2'>
            <Badge variant='secondary'>
              <HugeiconsIcon data-icon='inline-start' icon={Analytics01Icon} />
              {t('Performance health')}
            </Badge>
          </div>
          <CardTitle className='text-xl tracking-tight sm:text-2xl'>
            {t('Model Call Analytics')}
          </CardTitle>
        </CardHeader>
        <CardContent className='relative min-h-32 overflow-hidden px-0 md:min-h-full'>
          <svg
            aria-hidden='true'
            className='dashboard-analytics-art'
            viewBox='0 0 520 200'
            xmlns='http://www.w3.org/2000/svg'
          >
            <path
              className='dashboard-analytics-art-carrier'
              d='M58 44c34-24 81-27 122-10 27 11 45 12 71 4 42-13 91-8 119 17 25 23 29 66 6 94-26 31-76 34-119 22-34-10-66-10-100 2-44 16-91 8-111-22-20-30-17-83 12-107Z'
            />
            <path
              className='dashboard-analytics-art-gesture'
              d='M-12 126c61-10 100-42 146-70 31-19 55-15 85 5 35 24 57 19 88 2 34-19 61-17 93 8 32 25 64 33 120 27'
            />
            <path
              className='dashboard-analytics-art-contour'
              d='M82 87c29-17 52-23 77-17 18 4 32 13 47 25M291 106c20-11 38-13 56-6 17 6 28 16 46 25M333 50c26-11 52-9 73 4M146 145c26 8 48 6 70-4'
            />
            <circle
              className='dashboard-analytics-art-accent'
              cx='390'
              cy='129'
              r='8'
            />
          </svg>
        </CardContent>
      </div>
    </Card>
  )
}
