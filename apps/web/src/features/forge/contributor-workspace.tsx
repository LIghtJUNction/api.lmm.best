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
import {
  ArrowRight01Icon,
  Key01Icon,
  Wallet01Icon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'

import { SectionPageLayout } from '@/components/layout'
import { Button } from '@/components/ui/button'

import { AcceptedChallengeList } from './accepted-challenge-list'
import { ChallengeList } from './challenge-list'

export function ContributorWorkspace() {
  const { t } = useTranslation()

  return (
    <SectionPageLayout>
      <SectionPageLayout.Title>
        {t('Contributor workspace')}
      </SectionPageLayout.Title>
      <SectionPageLayout.Actions>
        <Button variant='outline' render={<Link to='/wallet' />}>
          <HugeiconsIcon
            icon={Wallet01Icon}
            data-icon='inline-start'
            strokeWidth={2}
            aria-hidden='true'
          />
          {t('Wallet')}
        </Button>
      </SectionPageLayout.Actions>
      <SectionPageLayout.Content>
        <div className='mx-auto max-w-6xl overflow-hidden border border-[#141413]/25 bg-[#FAF9F5] text-[#141413]'>
          <section className='grid gap-8 border-b border-[#141413] bg-[#D97757] px-6 py-9 md:grid-cols-[1fr_280px] md:px-10 md:py-12'>
            <div>
              <p className='mb-4 text-xs font-bold uppercase'>
                {t('Delivery workspace')}
              </p>
              <h1 className='mb-4 max-w-2xl font-serif text-4xl leading-tight font-normal md:text-5xl'>
                {t('Choose funded work and make progress visible.')}
              </h1>
              <p className='max-w-2xl text-sm leading-6 md:text-base'>
                {t(
                  'Accept a challenge, link the issue and pull request, then follow review and settlement in one evidence trail.'
                )}
              </p>
            </div>
            <div className='flex flex-col justify-end border-t border-[#141413]/40 pt-5 md:border-t-0 md:border-l md:pt-0 md:pl-7'>
              <HugeiconsIcon
                icon={Key01Icon}
                className='mb-5 size-7'
                strokeWidth={2}
                aria-hidden='true'
              />
              <p className='mb-5 text-sm leading-6'>
                {t(
                  'Developer access becomes available when you create your first credential. No payment is required to activate it.'
                )}
              </p>
              <Button
                className='w-full rounded-sm bg-[#141413] text-[#FAF9F5] hover:bg-[#141413]/85'
                render={<Link to='/developer-access' />}
              >
                {t('Developer access')}
                <HugeiconsIcon
                  icon={ArrowRight01Icon}
                  data-icon='inline-end'
                  strokeWidth={2}
                  aria-hidden='true'
                />
              </Button>
            </div>
          </section>
          <div className='px-6 py-9 md:px-10 md:py-12'>
            <ChallengeList limit={12} />
            <AcceptedChallengeList />
          </div>
        </div>
      </SectionPageLayout.Content>
    </SectionPageLayout>
  )
}
