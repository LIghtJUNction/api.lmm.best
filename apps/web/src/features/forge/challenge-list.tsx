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
  CircleDotIcon,
  GitPullRequestIcon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'

import { Skeleton } from '@/components/ui/skeleton'
import { listBounties } from '@/features/open-source-bounties/api'
import { useStatus } from '@/hooks/use-status'
import { getBackendCapabilities } from '@/lib/backend-capabilities'
import { formatQuota } from '@/lib/format'
import { cn } from '@/lib/utils'
import { useAuthStore } from '@/stores/auth-store'

type ChallengeListProps = {
  limit?: number
  className?: string
  showHeading?: boolean
}

function repositoryName(url: string): string {
  try {
    const parsed = new URL(url)
    return (
      parsed.pathname.replace(/^\//, '').replace(/\.git$/, '') || parsed.host
    )
  } catch {
    return url
  }
}

export function ChallengeList(props: ChallengeListProps) {
  const { t } = useTranslation()
  const limit = props.limit ?? 50
  const user = useAuthStore((state) => state.auth.user)
  const { status, capabilitiesReady } = useStatus()
  const canReadPublicBounties =
    getBackendCapabilities(status).bounty_public_read
  const query = useQuery({
    queryKey: ['forge-challenges'],
    queryFn: listBounties,
    enabled: Boolean(user) || (capabilitiesReady && canReadPublicBounties),
  })
  const items = (query.data?.items ?? []).slice(0, limit)

  return (
    <section className={cn('min-w-0', props.className)}>
      {props.showHeading !== false && (
        <div className='mb-6 flex items-end justify-between gap-5 border-b border-[#141413]/30 pb-5'>
          <div>
            <p className='mb-2 text-xs font-bold uppercase'>{t('Open work')}</p>
            <h2 className='font-serif text-3xl font-normal'>
              {t('Challenges')}
            </h2>
          </div>
          <span className='text-sm tabular-nums'>
            {query.data?.total ?? 0} {t('published')}
          </span>
        </div>
      )}

      <div className='border-t-2 border-[#141413]'>
        {query.isLoading &&
          Array.from({ length: Math.min(limit, 3) }, (_, index) => (
            <div
              key={index}
              className='grid min-h-24 grid-cols-[1fr_auto] items-center gap-5 border-b border-[#141413]/25 py-5'
            >
              <div className='flex flex-col gap-3'>
                <Skeleton className='h-5 w-2/3' />
                <Skeleton className='h-3 w-1/3' />
              </div>
              <Skeleton className='h-7 w-24' />
            </div>
          ))}

        {!query.isLoading && items.length === 0 && (
          <div className='border-b border-[#141413]/25 py-10 text-sm'>
            {query.isError
              ? t('Challenges are temporarily unavailable.')
              : t('No open challenges yet.')}
          </div>
        )}

        {items.map((challenge) => (
          <Link
            key={challenge.id}
            to='/challenges/$challengeId'
            params={{ challengeId: String(challenge.id) }}
            className='group grid min-h-24 grid-cols-[minmax(0,1fr)_auto] items-center gap-5 border-b border-[#141413]/25 py-4 transition-colors hover:bg-[#BCD1CA]/35 md:grid-cols-[minmax(280px,1fr)_150px_190px_28px] md:px-3'
          >
            <div className='min-w-0'>
              <h3 className='mb-1 truncate font-serif text-lg font-medium'>
                {challenge.title}
              </h3>
              <p className='text-muted-foreground truncate text-xs'>
                {repositoryName(challenge.repository_url)} · {t('by')}{' '}
                {challenge.owner_username}
              </p>
            </div>
            <div className='hidden items-center gap-2 text-xs font-semibold md:flex'>
              <HugeiconsIcon
                icon={CircleDotIcon}
                className='size-3 fill-current'
                strokeWidth={2}
                aria-hidden='true'
              />
              {t(challenge.status === 'published' ? 'Open' : challenge.status)}
            </div>
            <div className='hidden text-xs leading-5 md:block'>
              <span className='font-semibold tabular-nums'>
                {formatQuota(
                  challenge.net_reward_quota || challenge.reward_quota
                )}
              </span>{' '}
              {t('per delivery')}
              <span className='text-muted-foreground flex items-center gap-1'>
                <HugeiconsIcon
                  icon={GitPullRequestIcon}
                  className='size-3'
                  strokeWidth={2}
                  aria-hidden='true'
                />
                {challenge.approved_challenge_count}/{challenge.reward_slots}{' '}
                {t('approved')}
              </span>
            </div>
            <span className='justify-self-end text-sm font-semibold md:hidden'>
              {formatQuota(
                challenge.net_reward_quota || challenge.reward_quota
              )}
            </span>
            <HugeiconsIcon
              icon={ArrowRight01Icon}
              className='hidden size-5 transition-transform group-hover:translate-x-1 md:block'
              strokeWidth={2}
              aria-hidden='true'
            />
          </Link>
        ))}
      </div>
    </section>
  )
}
