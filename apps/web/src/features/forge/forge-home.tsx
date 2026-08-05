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
  GitPullRequestIcon,
  HeartHandshakeIcon,
  Tick02Icon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { isConsoleActivated } from '@/lib/console-activation'
import { useAuthStore } from '@/stores/auth-store'

import { ChallengeList } from './challenge-list'
import { ForgePublicShell } from './forge-public-shell'

function ForgeIllustration() {
  return (
    <div
      className='relative min-h-[220px] overflow-hidden sm:min-h-[280px] md:min-h-[410px]'
      aria-hidden='true'
    >
      <div className='absolute inset-[5%_2%_1%_1%] bg-[#FAF9F5] [clip-path:polygon(7%_13%,22%_4%,45%_7%,66%_2%,91%_13%,96%_36%,91%_57%,96%_80%,77%_95%,52%_91%,28%_98%,8%_84%,3%_56%)]' />
      <div className='absolute top-[28%] left-[10%] h-20 w-32 -rotate-6 border-4 border-[#141413] bg-[#FAF9F5] p-3 md:h-28 md:w-44 md:p-4'>
        <span className='mb-3 block h-1.5 bg-[#141413]' />
        <span className='mb-3 block h-1.5 w-3/4 bg-[#141413]' />
        <span className='block h-1.5 w-1/2 bg-[#141413]' />
      </div>
      <div className='absolute right-[9%] bottom-[16%] h-20 w-32 rotate-3 border-4 border-[#141413] bg-[#FAF9F5] p-3 md:h-28 md:w-44 md:p-4'>
        <span className='mb-3 block h-1.5 bg-[#141413]' />
        <span className='mb-3 block h-1.5 w-2/3 bg-[#141413]' />
        <HugeiconsIcon
          icon={Tick02Icon}
          className='absolute right-3 bottom-2 size-8 md:size-9'
          strokeWidth={3}
        />
      </div>
      <span className='absolute top-[48%] left-[39%] size-5 rounded-full bg-[#141413]' />
      <span className='absolute top-[61%] left-[54%] size-4 rounded-full bg-[#141413]' />
      <span className='absolute top-[47%] left-[69%] size-6 rounded-full bg-[#141413]' />
      <span className='absolute top-[50%] left-[40%] h-2 w-24 origin-left rotate-[28deg] rounded-full bg-[#141413] md:w-32' />
      <span className='absolute top-[64%] left-[54%] h-2 w-20 origin-left -rotate-[28deg] rounded-full bg-[#141413] md:w-28' />
      <HugeiconsIcon
        icon={GitPullRequestIcon}
        className='absolute top-[12%] right-[16%] size-12 rotate-6 md:size-16'
        strokeWidth={1.6}
      />
    </div>
  )
}

export function ForgeHome() {
  const { t } = useTranslation()
  const user = useAuthStore((state) => state.auth.user)
  const workspaceTarget = isConsoleActivated(user)
    ? '/open-source-bounties'
    : '/workspace'

  return (
    <ForgePublicShell>
      <main>
        <section className='border-b border-[#141413] bg-[#BCD1CA] pt-16'>
          <div className='mx-auto grid min-h-[calc(100svh-9rem)] max-w-7xl items-center gap-5 px-5 py-8 md:grid-cols-[0.92fr_1.08fr] md:px-10 md:py-12'>
            <div className='relative z-10'>
              <p className='mb-5 flex items-center gap-2 text-xs font-bold uppercase before:block before:size-2 before:rounded-full before:bg-[#141413]'>
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
                  className='rounded-sm bg-[#141413] text-[#FAF9F5] hover:bg-[#141413]/85'
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
                  className='rounded-sm border-[#141413] bg-transparent hover:bg-[#FAF9F5]/50'
                  render={
                    user ? (
                      <Link to={workspaceTarget} />
                    ) : (
                      <Link to='/sign-in' />
                    )
                  }
                >
                  {user ? t('Open workspace') : t('Sign in')}
                </Button>
              </div>
            </div>
            <ForgeIllustration />
          </div>
        </section>

        <section className='border-b border-[#141413] bg-[#FAF9F5]'>
          <div className='mx-auto grid max-w-7xl md:grid-cols-[250px_1fr] md:px-10'>
            <div className='border-b border-[#141413]/30 px-5 py-8 md:border-r md:border-b-0 md:px-0 md:pr-8'>
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
                className='inline-flex items-center gap-2 border-b border-[#141413] pb-1 text-sm font-bold'
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
          className='border-b border-[#141413] py-20 md:py-28'
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
            <div className='grid border-t-2 border-[#141413] sm:grid-cols-2 lg:grid-cols-4'>
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
                  className='relative min-h-64 border-b border-[#141413]/25 py-7 sm:odd:border-r sm:odd:pr-6 sm:even:pl-6 lg:border-r lg:border-b-0 lg:px-6 lg:first:pl-0 lg:last:border-r-0'
                >
                  <span className='absolute -top-2 left-0 size-4 rounded-full bg-[#141413] lg:left-6 lg:first:left-0' />
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

        <section className='border-b border-[#141413] bg-[#BCD1CA] py-20 md:py-28'>
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
            <dl className='border-t-2 border-[#141413]'>
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
                  className='grid gap-2 border-b border-[#141413]/35 py-6 sm:grid-cols-[130px_1fr] sm:gap-6'
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
