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
  HeartHandshakeIcon,
  WalletCardsIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { isConsoleActivated } from '@/lib/console-activation'
import { useAuthStore } from '@/stores/auth-store'

import { ChallengeList } from './challenge-list'
import { ForgeBountyHeroArt } from './forge-bounty-hero-art'
import { ForgePublicShell } from './forge-public-shell'

export function ForgeHome() {
  const { t } = useTranslation()
  const user = useAuthStore((state) => state.auth.user)
  const workspaceTarget = isConsoleActivated(user)
    ? '/open-source-bounties'
    : '/workspace'

  return (
    <ForgePublicShell>
      <main>
        <section className='border-border bg-background border-b pt-16'>
          <div className='mx-auto grid min-h-[calc(100svh-9rem)] max-w-7xl items-center gap-10 px-5 py-10 md:px-10 md:py-12 lg:grid-cols-[minmax(0,0.42fr)_minmax(0,0.58fr)] lg:gap-6'>
            <div className='relative z-10 max-w-xl'>
              <p className='before:bg-foreground mb-5 flex items-center gap-2 text-xs font-bold uppercase before:block before:size-2 before:rounded-full'>
                {t('Open-source work, made accountable')}
              </p>
              <h1 className='mb-7 max-w-3xl font-serif text-5xl leading-[1.02] font-normal md:text-7xl'>
                LMM Forge
              </h1>
              <p className='mb-8 max-w-2xl text-base leading-7 md:text-lg'>
                {t(
                  'Fund open-source work, coordinate contributors, and track every delivery from accepted challenge to verified pull request.'
                )}
              </p>
              <div className='flex flex-col gap-3 sm:flex-row'>
                <Button
                  size='lg'
                  className='rounded-sm'
                  render={<Link to='/challenges' />}
                >
                  {t('Browse challenges')}
                  <HugeiconsIcon
                    icon={ArrowRight01Icon}
                    data-icon='inline-end'
                    strokeWidth={2}
                    aria-hidden='true'
                  />
                </Button>
                <Button
                  size='lg'
                  variant='outline'
                  className='rounded-sm'
                  render={
                    user ? (
                      <Link to={workspaceTarget} />
                    ) : (
                      <Link to='/pricing' />
                    )
                  }
                >
                  {user ? t('Open workspace') : t('Explore access options')}
                </Button>
              </div>
            </div>
            <ForgeBountyHeroArt />
          </div>
        </section>

        <section className='border-border bg-background border-b'>
          <div className='mx-auto grid max-w-7xl md:grid-cols-[250px_1fr] md:px-10'>
            <div className='border-border border-b px-5 py-8 md:border-r md:border-b-0 md:px-0 md:pr-8'>
              <p className='mb-3 text-xs font-bold uppercase'>
                {t('Live board')}
              </p>
              <h2 className='mb-4 font-serif text-3xl font-normal'>
                {t('Open work')}
              </h2>
              <p className='mb-5 text-sm leading-6'>
                {t(
                  'Published work below is loaded from the real challenge ledger.'
                )}
              </p>
              <Link
                to='/challenges'
                className='border-foreground inline-flex items-center gap-2 border-b pb-1 text-sm font-bold'
              >
                {t('View all')}
                <HugeiconsIcon
                  icon={ArrowRight01Icon}
                  className='size-4'
                  strokeWidth={2}
                  aria-hidden='true'
                />
              </Link>
            </div>
            <div className='px-5 py-3 md:pl-8'>
              <ChallengeList limit={3} showHeading={false} />
            </div>
          </div>
        </section>

        <section
          id='workflow'
          className='border-border border-b py-20 md:py-28'
        >
          <div className='mx-auto max-w-7xl px-5 md:px-10'>
            <div className='mb-14 grid gap-8 md:grid-cols-2 md:items-end'>
              <h2 className='max-w-3xl font-serif text-4xl leading-tight font-normal md:text-6xl'>
                {t('A delivery trail people can actually review.')}
              </h2>
              <p className='max-w-xl text-base leading-7 md:justify-self-end'>
                {t(
                  'Scope, acceptance, evidence, review, settlement, ratings, tips, and disputes stay connected to the same funded challenge.'
                )}
              </p>
            </div>
            <div className='border-foreground grid border-t-2 sm:grid-cols-2 lg:grid-cols-4'>
              {[
                [
                  '01',
                  'Publish and fund',
                  'Define the repository, reward, slots, rules, and escrow.',
                ],
                [
                  '02',
                  'Accept the work',
                  'A contributor claims a slot with a verifiable GitHub identity.',
                ],
                [
                  '03',
                  'Attach evidence',
                  'Link the issue, pull request, and delivery notes in one trail.',
                ],
                [
                  '04',
                  'Review and settle',
                  'Approve the work, release the reward, rate, tip, or dispute.',
                ],
              ].map(([index, title, description]) => (
                <article
                  key={index}
                  className='border-border relative min-h-64 border-b py-7 sm:odd:border-r sm:odd:pr-6 sm:even:pl-6 lg:border-r lg:border-b-0 lg:px-6 lg:first:pl-0 lg:last:border-r-0'
                >
                  <span className='bg-foreground absolute -top-2 left-0 size-4 rounded-full lg:left-6 lg:first:left-0' />
                  <span className='mb-12 block text-xs font-bold'>{index}</span>
                  <h3 className='mb-4 font-serif text-2xl font-medium'>
                    {t(title)}
                  </h3>
                  <p className='text-sm leading-6 opacity-75'>
                    {t(description)}
                  </p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className='border-border bg-muted/60 border-b py-16 md:py-20'>
          <div className='mx-auto grid max-w-7xl gap-8 px-5 md:grid-cols-[auto_1fr_auto] md:items-center md:px-10'>
            <HugeiconsIcon
              icon={WalletCardsIcon}
              className='size-10'
              strokeWidth={2}
              aria-hidden='true'
            />
            <div>
              <h2 className='font-serif text-3xl leading-tight font-normal md:text-4xl'>
                {t('Need a dependable starting point?')}
              </h2>
              <p className='mt-3 max-w-2xl text-sm leading-6 md:text-base'>
                {t(
                  'Create an account, add usage credit when you are ready, and pay only for what you use.'
                )}
              </p>
            </div>
            <Button
              variant='outline'
              className='rounded-sm'
              render={<Link to='/pricing' />}
            >
              {t('View access options')}
              <HugeiconsIcon
                icon={ArrowRight01Icon}
                data-icon='inline-end'
                strokeWidth={2}
                aria-hidden='true'
              />
            </Button>
          </div>
        </section>

        <section className='border-border bg-accent/60 border-b py-20 md:py-28'>
          <div className='mx-auto grid max-w-7xl gap-12 px-5 md:grid-cols-[0.9fr_1.1fr] md:px-10'>
            <div>
              <HugeiconsIcon
                icon={HeartHandshakeIcon}
                className='mb-8 size-10'
                strokeWidth={2}
                aria-hidden='true'
              />
              <h2 className='mb-6 max-w-2xl font-serif text-4xl leading-tight font-normal md:text-6xl'>
                {t('Trust comes from evidence, not a progress label.')}
              </h2>
              <p className='max-w-xl text-base leading-7'>
                {t(
                  'Every funded action leaves a visible record for project owners and contributors.'
                )}
              </p>
            </div>
            <dl className='border-foreground border-t-2'>
              {[
                [
                  'Challenge',
                  'Repository, scope, reward, rules, and delivery slots',
                ],
                [
                  'Evidence',
                  'Issue, pull request, contributor note, and reviewer decision',
                ],
                [
                  'Settlement',
                  'Escrow funding, reward transfer, refund, tip, and dispute history',
                ],
              ].map(([term, description]) => (
                <div
                  key={term}
                  className='border-border grid gap-2 border-b py-6 sm:grid-cols-[130px_1fr] sm:gap-6'
                >
                  <dt className='text-xs font-bold uppercase'>{t(term)}</dt>
                  <dd className='font-serif text-lg'>{t(description)}</dd>
                </div>
              ))}
            </dl>
          </div>
        </section>
      </main>
    </ForgePublicShell>
  )
}
