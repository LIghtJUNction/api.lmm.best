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

const MODEL_ANALYTICS_ART = '/model-analytics-anthropic.webp'

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
          <img
            alt={t('Model Call Analytics')}
            className='absolute inset-0 size-full object-cover'
            decoding='async'
            fetchPriority='high'
            src={MODEL_ANALYTICS_ART}
          />
        </CardContent>
      </div>
    </Card>
  )
}
