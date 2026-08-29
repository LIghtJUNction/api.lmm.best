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
import { GitPullRequest, ShieldCheck, Wallet } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { ForgePublicShell } from '@/features/forge/forge-public-shell'

export function HowItWorks() {
  const { t } = useTranslation()

  return (
    <ForgePublicShell>
      <main className='mx-auto max-w-7xl px-5 pt-32 pb-24 md:px-10 md:pt-40'>
        <header className='grid gap-12 md:grid-cols-[minmax(0,0.95fr)_minmax(16rem,0.55fr)] md:items-end'>
          <div>
            <p className='mb-5 flex items-center gap-2 text-xs font-bold uppercase'>
              <span className='bg-foreground size-2 rounded-full' />
              {t('How it works')}
            </p>
            <h1 className='max-w-3xl font-serif text-5xl leading-[1.02] font-normal md:text-7xl'>
              {t('Open-source work, made accountable.')}
            </h1>
            <p className='text-muted-foreground mt-7 max-w-2xl text-base leading-7 md:text-lg'>
              {t(
                'Publish a funded challenge, accept the work, then review evidence before escrow is released.'
              )}
            </p>
          </div>
          <p className='border-foreground text-muted-foreground border-t-2 pt-5 text-sm leading-6'>
            {t('Open-source bounty collaboration')}
          </p>
        </header>

        <ol className='border-foreground mt-16 border-t-2'>
          <li className='border-border grid gap-5 border-b py-8 md:grid-cols-[4.5rem_minmax(0,1fr)_auto] md:items-start md:py-10'>
            <span className='font-serif text-2xl tabular-nums'>01</span>
            <div className='min-w-0'>
              <h2 className='font-serif text-2xl font-normal md:text-3xl'>
                {t('Publish and fund')}
              </h2>
              <p className='text-muted-foreground mt-3 max-w-2xl text-sm leading-6 md:text-base'>
                {t(
                  'Lock a reward pool against a public repository and acceptance rules.'
                )}
              </p>
            </div>
            <Wallet
              className='text-foreground size-8 md:mt-1'
              aria-hidden='true'
            />
          </li>
          <li className='border-border grid gap-5 border-b py-8 md:grid-cols-[4.5rem_minmax(0,1fr)_auto] md:items-start md:py-10'>
            <span className='font-serif text-2xl tabular-nums'>02</span>
            <div className='min-w-0'>
              <h2 className='font-serif text-2xl font-normal md:text-3xl'>
                {t('Accept an open-source bounty')}
              </h2>
              <p className='text-muted-foreground mt-3 max-w-2xl text-sm leading-6 md:text-base'>
                {t(
                  'Contributors pick an open slot, fix the defect, and attach the matching Issue or pull request.'
                )}
              </p>
            </div>
            <GitPullRequest
              className='text-foreground size-8 md:mt-1'
              aria-hidden='true'
            />
          </li>
          <li className='border-border grid gap-5 border-b py-8 md:grid-cols-[4.5rem_minmax(0,1fr)_auto] md:items-start md:py-10'>
            <span className='font-serif text-2xl tabular-nums'>03</span>
            <div className='min-w-0'>
              <h2 className='font-serif text-2xl font-normal md:text-3xl'>
                {t('Review submissions')}
              </h2>
              <p className='text-muted-foreground mt-3 max-w-2xl text-sm leading-6 md:text-base'>
                {t(
                  'Publishers inspect evidence, then approve payment or reject with a recorded reason.'
                )}
              </p>
            </div>
            <ShieldCheck
              className='text-foreground size-8 md:mt-1'
              aria-hidden='true'
            />
          </li>
        </ol>

        <div className='mt-12 flex flex-wrap gap-3'>
          <Button
            size='lg'
            className='h-12 rounded-none px-6'
            render={<Link to='/challenges' />}
          >
            {t('Browse challenges')}
          </Button>
          <Button
            variant='outline'
            size='lg'
            className='h-12 rounded-none px-6'
            render={<Link to='/guide' />}
          >
            {t('Read the guide')}
          </Button>
        </div>
      </main>
    </ForgePublicShell>
  )
}
