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
  Award01Icon,
  Bug01Icon,
  CancelCircleIcon,
  CheckmarkCircle02Icon,
  Delete02Icon,
  ExternalLinkIcon,
  FileEditIcon,
  GithubIcon,
  Loading03Icon,
  Megaphone01Icon,
  MoneyLockIcon,
  PauseIcon,
  PlayIcon,
  PlusSignIcon,
  SourceCodeIcon,
  Upload01Icon,
  UserAdd01Icon,
} from '@hugeicons/core-free-icons'
import { HugeiconsIcon } from '@hugeicons/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Dialog } from '@/components/dialog'
import { Main } from '@/components/layout'
import {
  CardStaggerContainer,
  CardStaggerItem,
} from '@/components/page-transition'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from '@/components/ui/empty'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Textarea } from '@/components/ui/textarea'
import { TitledCard } from '@/components/ui/titled-card'
import { getSelf } from '@/lib/api'
import {
  formatQuota,
  parseQuotaFromDollars,
  quotaUnitsToDollars,
} from '@/lib/format'
import { useAuthStore } from '@/stores/auth-store'

import {
  acceptBounty,
  closeBounty,
  createBounty,
  deleteBounty,
  getBountyDetail,
  listAcceptedBounties,
  listBounties,
  listOwnedBounties,
  pauseBounty,
  publishBounty,
  resumeBounty,
  reviewChallenge,
  submitChallenge,
  updateBounty,
  withdrawChallenge,
} from './api'
import type {
  BountyChallenge,
  BountyDraftInput,
  BountyProject,
  BountyProjectDetail,
} from './types'

const BOUNTY_QUERY_KEYS = [
  ['open-source-bounties'],
  ['open-source-bounties', 'mine'],
  ['open-source-bounties', 'accepted'],
] as const

const STATUS_KEYS = {
  draft: 'Draft',
  published: 'Published',
  paused: 'Paused',
  completed: 'Completed',
  closed: 'Closed',
  accepted: 'Accepted',
  submitted: 'Submitted',
  approved: 'Approved',
  rejected: 'Rejected',
  withdrawn: 'Withdrawn',
} as const

const ERROR_KEYS: Record<string, string> = {
  OPEN_SOURCE_BOUNTY_INSUFFICIENT_BALANCE:
    'Your balance is not enough to publish this bounty.',
  OPEN_SOURCE_BOUNTY_ACTIVE_CHALLENGES:
    'Resolve or reject active challenges before closing this bounty.',
  OPEN_SOURCE_BOUNTY_FULL: 'All reward slots are currently occupied.',
  OPEN_SOURCE_BOUNTY_ALREADY_ACCEPTED:
    'You have already accepted this challenge.',
  OPEN_SOURCE_BOUNTY_EVIDENCE_REPOSITORY_MISMATCH:
    'The Issue and pull request must belong to the bounty repository.',
  OPEN_SOURCE_BOUNTY_DUPLICATE_PULL_REQUEST:
    'This pull request has already been submitted.',
}

type DraftForm = {
  repositoryUrl: string
  title: string
  description: string
  rules: string
  promotionAmount: number
  rewardAmount: number
  rewardSlots: number
}

const EMPTY_DRAFT: DraftForm = {
  repositoryUrl: '',
  title: '',
  description: '',
  rules: '',
  promotionAmount: 0,
  rewardAmount: 0,
  rewardSlots: 1,
}

function projectToDraft(project: BountyProject): DraftForm {
  return {
    repositoryUrl: project.repository_url,
    title: project.title,
    description: project.description,
    rules: project.rules,
    promotionAmount: quotaUnitsToDollars(project.promotion_quota),
    rewardAmount: quotaUnitsToDollars(project.reward_quota),
    rewardSlots: project.reward_slots,
  }
}

function statusLabel(t: (key: string) => string, status: string) {
  return t(STATUS_KEYS[status as keyof typeof STATUS_KEYS] ?? status)
}

function availableSlots(project: BountyProject) {
  return Math.max(
    0,
    project.reward_slots -
      project.active_challenge_count -
      project.approved_challenge_count
  )
}

export function OpenSourceBounties() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const user = useAuthStore((state) => state.auth.user)
  const setUser = useAuthStore((state) => state.auth.setUser)
  const [pending, setPending] = useState('')
  const [draftOpen, setDraftOpen] = useState(false)
  const [editingProject, setEditingProject] = useState<BountyProject | null>(
    null
  )
  const [draft, setDraft] = useState<DraftForm>(EMPTY_DRAFT)
  const [acceptProject, setAcceptProject] = useState<BountyProject | null>(null)
  const [githubHandle, setGithubHandle] = useState('')
  const [submitTarget, setSubmitTarget] = useState<{
    projectId: number
    challenge: BountyChallenge
  } | null>(null)
  const [submission, setSubmission] = useState({
    issueUrl: '',
    pullRequestUrl: '',
    encryptedReviewMessage: '',
    submissionNote: '',
  })
  const [detail, setDetail] = useState<BountyProjectDetail | null>(null)
  const [detailOpen, setDetailOpen] = useState(false)
  const [reviewTarget, setReviewTarget] = useState<{
    challenge: BountyChallenge
    action: 'approve' | 'reject'
  } | null>(null)
  const [reviewNote, setReviewNote] = useState('')

  const bountyQuery = useQuery({
    queryKey: BOUNTY_QUERY_KEYS[0],
    queryFn: listBounties,
  })
  const ownedQuery = useQuery({
    queryKey: BOUNTY_QUERY_KEYS[1],
    queryFn: listOwnedBounties,
  })
  const acceptedQuery = useQuery({
    queryKey: BOUNTY_QUERY_KEYS[2],
    queryFn: listAcceptedBounties,
  })

  const totalDraftQuota = useMemo(() => {
    const promotion = parseQuotaFromDollars(draft.promotionAmount)
    const reward = parseQuotaFromDollars(draft.rewardAmount)
    return promotion + reward * Math.max(0, draft.rewardSlots)
  }, [draft.promotionAmount, draft.rewardAmount, draft.rewardSlots])

  const refresh = async (balanceChanged = false) => {
    await Promise.all(
      BOUNTY_QUERY_KEYS.map((queryKey) =>
        queryClient.invalidateQueries({ queryKey })
      )
    )
    if (balanceChanged) {
      const response = await getSelf()
      if (response.success && response.data) setUser(response.data)
    }
  }

  const errorMessage = (error: unknown) => {
    const code = (error as Error & { code?: string })?.code
    return t(
      (code && ERROR_KEYS[code]) || 'Unable to complete the bounty action.'
    )
  }

  const runAction = async (
    key: string,
    action: () => Promise<unknown>,
    successMessage: string,
    balanceChanged = false
  ) => {
    setPending(key)
    try {
      await action()
      await refresh(balanceChanged)
      toast.success(t(successMessage))
      return true
    } catch (error) {
      toast.error(errorMessage(error))
      return false
    } finally {
      setPending('')
    }
  }

  const openCreateDialog = () => {
    setEditingProject(null)
    setDraft(EMPTY_DRAFT)
    setDraftOpen(true)
  }

  const openEditDialog = (project: BountyProject) => {
    setEditingProject(project)
    setDraft(projectToDraft(project))
    setDraftOpen(true)
  }

  const saveDraft = async () => {
    const input: BountyDraftInput = {
      repository_url: draft.repositoryUrl.trim(),
      title: draft.title.trim(),
      description: draft.description.trim(),
      rules: draft.rules.trim(),
      promotion_quota: parseQuotaFromDollars(draft.promotionAmount),
      reward_quota: parseQuotaFromDollars(draft.rewardAmount),
      reward_slots: draft.rewardSlots,
    }
    if (
      !input.repository_url ||
      input.title.length < 4 ||
      input.description.length < 20 ||
      input.rules.length < 20 ||
      input.promotion_quota <= 0 ||
      input.reward_quota <= 0 ||
      input.reward_slots < 1
    ) {
      toast.error(t('Complete every bounty field with valid values.'))
      return
    }
    const success = await runAction(
      'save-draft',
      () =>
        editingProject
          ? updateBounty(editingProject.id, input)
          : createBounty(input),
      editingProject ? 'Bounty draft updated.' : 'Bounty draft created.'
    )
    if (success) setDraftOpen(false)
  }

  const openProjectDetail = async (projectId: number) => {
    setPending(`detail-${projectId}`)
    try {
      setDetail(await getBountyDetail(projectId))
      setDetailOpen(true)
    } catch (error) {
      toast.error(errorMessage(error))
    } finally {
      setPending('')
    }
  }

  const handleAccept = async () => {
    if (!acceptProject || githubHandle.trim().length < 1) return
    const success = await runAction(
      `accept-${acceptProject.id}`,
      () => acceptBounty(acceptProject.id, githubHandle.trim()),
      'Challenge accepted.'
    )
    if (success) {
      setAcceptProject(null)
      setGithubHandle('')
    }
  }

  const handleSubmit = async () => {
    if (!submitTarget) return
    const success = await runAction(
      `submit-${submitTarget.challenge.id}`,
      () =>
        submitChallenge(submitTarget.projectId, {
          issue_url: submission.issueUrl.trim(),
          pull_request_url: submission.pullRequestUrl.trim(),
          encrypted_review_message: submission.encryptedReviewMessage.trim(),
          submission_note: submission.submissionNote.trim(),
        }),
      'Bounty work submitted for review.'
    )
    if (success) {
      setSubmitTarget(null)
      setSubmission({
        issueUrl: '',
        pullRequestUrl: '',
        encryptedReviewMessage: '',
        submissionNote: '',
      })
    }
  }

  const handleReview = async () => {
    if (!reviewTarget) return
    const { challenge, action } = reviewTarget
    const success = await runAction(
      `${action}-${challenge.id}`,
      () => reviewChallenge(challenge.id, action, reviewNote.trim()),
      action === 'approve'
        ? 'Submission approved and reward transferred.'
        : 'Submission rejected.',
      action === 'approve'
    )
    if (success) {
      setReviewTarget(null)
      setReviewNote('')
      setDetail(await getBountyDetail(challenge.project_id))
    }
  }

  const openSubmitDialog = (projectId: number, challenge: BountyChallenge) => {
    setSubmitTarget({ projectId, challenge })
    setSubmission({
      issueUrl: challenge.issue_url || '',
      pullRequestUrl: challenge.pull_request_url || '',
      encryptedReviewMessage: challenge.encrypted_review_message || '',
      submissionNote: challenge.submission_note || '',
    })
  }

  let bountyBoardContent: React.ReactNode
  if (bountyQuery.isLoading) {
    bountyBoardContent = <LoadingState label={t('Loading bounties...')} />
  } else if ((bountyQuery.data?.items.length ?? 0) === 0) {
    bountyBoardContent = (
      <Empty className='min-h-72 border'>
        <EmptyHeader>
          <EmptyMedia variant='icon'>
            <HugeiconsIcon icon={Megaphone01Icon} strokeWidth={2} />
          </EmptyMedia>
          <EmptyTitle>{t('No promoted bounty projects yet')}</EmptyTitle>
          <EmptyDescription>
            {t(
              'The board starts empty. Publish the first project by spending your own balance and funding its reward pool.'
            )}
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button onClick={openCreateDialog}>{t('Create bounty')}</Button>
        </EmptyContent>
      </Empty>
    )
  } else {
    bountyBoardContent = (
      <div className='grid gap-4 lg:grid-cols-2'>
        {bountyQuery.data?.items.map((project) => (
          <BountyCard
            key={project.id}
            project={project}
            viewerUserId={user?.id ?? 0}
            pending={pending}
            onAccept={() => setAcceptProject(project)}
            onSubmit={(challenge) => openSubmitDialog(project.id, challenge)}
          />
        ))}
      </div>
    )
  }

  return (
    <Main>
      <div className='min-h-0 flex-1 overflow-auto px-3 py-3 sm:px-4 sm:py-6'>
        <CardStaggerContainer className='mx-auto flex w-full max-w-7xl flex-col gap-4 sm:gap-6'>
          <CardStaggerItem>
            <div className='flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between'>
              <div className='flex items-start gap-3 sm:gap-4'>
                <div className='bg-primary/10 text-primary flex size-10 shrink-0 items-center justify-center rounded-xl sm:size-12'>
                  <HugeiconsIcon
                    icon={Award01Icon}
                    strokeWidth={1.8}
                    className='size-5 sm:size-6'
                  />
                </div>
                <div className='min-w-0'>
                  <h1 className='text-xl font-bold tracking-tight sm:text-2xl'>
                    {t('Open-source bounties')}
                  </h1>
                  <p className='text-muted-foreground mt-1 max-w-3xl text-sm leading-relaxed'>
                    {t(
                      'Publish real bug-fix challenges, accept work, verify the fix, and transfer rewards from escrow.'
                    )}
                  </p>
                </div>
              </div>
              <Button onClick={openCreateDialog}>
                <HugeiconsIcon
                  icon={PlusSignIcon}
                  strokeWidth={2}
                  data-icon='inline-start'
                />
                {t('Create bounty')}
              </Button>
            </div>
          </CardStaggerItem>

          <CardStaggerItem>
            <Alert>
              <HugeiconsIcon icon={MoneyLockIcon} strokeWidth={2} />
              <AlertTitle>
                {t('Every publisher pays from their own balance')}
              </AlertTitle>
              <AlertDescription>
                {t(
                  'Publishing burns the promotion spend and locks the full reward pool. This rule also applies to administrators and the site owner.'
                )}
              </AlertDescription>
            </Alert>
          </CardStaggerItem>

          <CardStaggerItem>
            <Tabs defaultValue='browse'>
              <TabsList className='w-full justify-start overflow-x-auto sm:w-auto'>
                <TabsTrigger value='browse'>{t('Bounty board')}</TabsTrigger>
                <TabsTrigger value='owned'>
                  {t('My bounty projects')}
                </TabsTrigger>
                <TabsTrigger value='accepted'>{t('My challenges')}</TabsTrigger>
                <TabsTrigger value='rules'>{t('Rules')}</TabsTrigger>
              </TabsList>

              <TabsContent value='browse' className='mt-3 sm:mt-4'>
                {bountyBoardContent}
              </TabsContent>

              <TabsContent value='owned' className='mt-3 sm:mt-4'>
                {(ownedQuery.data?.length ?? 0) === 0 ? (
                  <Empty className='min-h-72 border'>
                    <EmptyHeader>
                      <EmptyMedia variant='icon'>
                        <HugeiconsIcon icon={SourceCodeIcon} strokeWidth={2} />
                      </EmptyMedia>
                      <EmptyTitle>
                        {t('You have no bounty projects')}
                      </EmptyTitle>
                      <EmptyDescription>
                        {t(
                          'Create a draft, fund it from your balance, then publish it to the board.'
                        )}
                      </EmptyDescription>
                    </EmptyHeader>
                    <EmptyContent>
                      <Button onClick={openCreateDialog}>
                        {t('Create bounty')}
                      </Button>
                    </EmptyContent>
                  </Empty>
                ) : (
                  <div className='grid gap-4'>
                    {ownedQuery.data?.map((project) => (
                      <OwnerProjectCard
                        key={project.id}
                        project={project}
                        pending={pending}
                        onEdit={() => openEditDialog(project)}
                        onReview={() => openProjectDetail(project.id)}
                        onPublish={() =>
                          runAction(
                            `publish-${project.id}`,
                            () => publishBounty(project.id),
                            'Bounty published and reward pool funded.',
                            true
                          )
                        }
                        onPause={() =>
                          runAction(
                            `pause-${project.id}`,
                            () => pauseBounty(project.id),
                            'Bounty paused.'
                          )
                        }
                        onResume={() =>
                          runAction(
                            `resume-${project.id}`,
                            () => resumeBounty(project.id),
                            'Bounty resumed.'
                          )
                        }
                        onClose={() =>
                          runAction(
                            `close-${project.id}`,
                            () => closeBounty(project.id),
                            'Bounty closed and unused escrow refunded.',
                            true
                          )
                        }
                        onDelete={() =>
                          runAction(
                            `delete-${project.id}`,
                            () => deleteBounty(project.id),
                            'Bounty draft deleted.'
                          )
                        }
                      />
                    ))}
                  </div>
                )}
              </TabsContent>

              <TabsContent value='accepted' className='mt-3 sm:mt-4'>
                {(acceptedQuery.data?.length ?? 0) === 0 ? (
                  <Empty className='min-h-72 border'>
                    <EmptyHeader>
                      <EmptyMedia variant='icon'>
                        <HugeiconsIcon icon={Bug01Icon} strokeWidth={2} />
                      </EmptyMedia>
                      <EmptyTitle>
                        {t('You have not accepted a challenge')}
                      </EmptyTitle>
                      <EmptyDescription>
                        {t(
                          'Accept an available bounty, fix a real defect, and submit the matching Issue and pull request.'
                        )}
                      </EmptyDescription>
                    </EmptyHeader>
                  </Empty>
                ) : (
                  <div className='grid gap-4 lg:grid-cols-2'>
                    {acceptedQuery.data?.map((challenge) => (
                      <ChallengeCard
                        key={challenge.id}
                        challenge={challenge}
                        pending={pending}
                        onSubmit={() =>
                          openSubmitDialog(challenge.project_id, challenge)
                        }
                        onWithdraw={() =>
                          runAction(
                            `withdraw-${challenge.id}`,
                            () => withdrawChallenge(challenge.id),
                            'Challenge withdrawn.'
                          )
                        }
                      />
                    ))}
                  </div>
                )}
              </TabsContent>

              <TabsContent value='rules' className='mt-3 sm:mt-4'>
                <RulesPanel />
              </TabsContent>
            </Tabs>
          </CardStaggerItem>
        </CardStaggerContainer>
      </div>

      <DraftDialog
        open={draftOpen}
        onOpenChange={setDraftOpen}
        editing={Boolean(editingProject)}
        draft={draft}
        setDraft={setDraft}
        totalQuota={totalDraftQuota}
        availableQuota={user?.quota ?? 0}
        pending={pending === 'save-draft'}
        onSave={saveDraft}
      />

      <Dialog
        open={Boolean(acceptProject)}
        onOpenChange={(open) => !open && setAcceptProject(null)}
        title={t('Accept challenge')}
        description={t(
          'Reserve one reward slot and identify your GitHub account.'
        )}
        contentClassName='sm:max-w-md'
        footer={
          <>
            <Button variant='outline' onClick={() => setAcceptProject(null)}>
              {t('Cancel')}
            </Button>
            <Button
              onClick={handleAccept}
              disabled={!githubHandle.trim() || pending.startsWith('accept-')}
            >
              {t('Accept challenge')}
            </Button>
          </>
        }
      >
        <div className='flex flex-col gap-2 py-2'>
          <Label htmlFor='bounty-github-handle'>{t('GitHub handle')}</Label>
          <Input
            id='bounty-github-handle'
            value={githubHandle}
            onChange={(event) => setGithubHandle(event.target.value)}
            placeholder='@username'
          />
        </div>
      </Dialog>

      <SubmissionDialog
        target={submitTarget}
        onOpenChange={(open) => !open && setSubmitTarget(null)}
        submission={submission}
        setSubmission={setSubmission}
        pending={pending.startsWith('submit-')}
        onSubmit={handleSubmit}
      />

      <ProjectReviewDialog
        open={detailOpen}
        onOpenChange={setDetailOpen}
        detail={detail}
        pending={pending}
        onReview={(challenge, action) => {
          setReviewTarget({ challenge, action })
          setReviewNote('')
        }}
      />

      <Dialog
        open={Boolean(reviewTarget)}
        onOpenChange={(open) => !open && setReviewTarget(null)}
        title={
          reviewTarget?.action === 'approve'
            ? t('Approve and transfer reward')
            : t('Reject submission')
        }
        description={
          reviewTarget?.action === 'approve'
            ? t(
                'Approval transfers the locked reward directly to the contributor balance and cannot be repeated.'
              )
            : t('Rejection releases the reward slot for another contributor.')
        }
        contentClassName='sm:max-w-lg'
        footer={
          <>
            <Button variant='outline' onClick={() => setReviewTarget(null)}>
              {t('Cancel')}
            </Button>
            <Button
              variant={
                reviewTarget?.action === 'reject' ? 'destructive' : 'default'
              }
              onClick={handleReview}
              disabled={
                pending.startsWith('approve-') || pending.startsWith('reject-')
              }
            >
              {reviewTarget?.action === 'approve'
                ? t('Approve and pay')
                : t('Reject')}
            </Button>
          </>
        }
      >
        <div className='flex flex-col gap-2 py-2'>
          <Label htmlFor='bounty-review-note'>
            {t('Review note (optional)')}
          </Label>
          <Textarea
            id='bounty-review-note'
            rows={5}
            value={reviewNote}
            onChange={(event) => setReviewNote(event.target.value)}
          />
        </div>
      </Dialog>
    </Main>
  )
}

function LoadingState({ label }: { label: string }) {
  return (
    <div className='text-muted-foreground flex min-h-64 items-center justify-center gap-2 text-sm'>
      <HugeiconsIcon
        icon={Loading03Icon}
        strokeWidth={2}
        className='size-5 animate-spin'
      />
      {label}
    </div>
  )
}

function BountyCard({
  project,
  viewerUserId,
  pending,
  onAccept,
  onSubmit,
}: {
  project: BountyProject
  viewerUserId: number
  pending: string
  onAccept: () => void
  onSubmit: (challenge: BountyChallenge) => void
}) {
  const { t } = useTranslation()
  const challenge = project.viewer_challenge
  const slots = availableSlots(project)
  let viewerAction: React.ReactNode
  if (project.owner_user_id === viewerUserId) {
    viewerAction = <Badge variant='secondary'>{t('Managed by you')}</Badge>
  } else if (challenge?.status === 'accepted') {
    viewerAction = (
      <Button onClick={() => onSubmit(challenge)}>
        <HugeiconsIcon
          icon={Upload01Icon}
          strokeWidth={2}
          data-icon='inline-start'
        />
        {t('Submit work')}
      </Button>
    )
  } else if (challenge) {
    viewerAction = (
      <Badge variant='outline'>{statusLabel(t, challenge.status)}</Badge>
    )
  } else {
    viewerAction = (
      <Button
        onClick={onAccept}
        disabled={
          project.status !== 'published' || slots === 0 || pending !== ''
        }
      >
        <HugeiconsIcon
          icon={UserAdd01Icon}
          strokeWidth={2}
          data-icon='inline-start'
        />
        {t('Accept challenge')}
      </Button>
    )
  }
  return (
    <TitledCard
      title={project.title}
      description={`${project.owner_username} · ${statusLabel(t, project.status)}`}
      icon={<HugeiconsIcon icon={Bug01Icon} strokeWidth={1.8} />}
      iconTone='primary'
      disableHoverEffect
      contentClassName='flex h-full flex-col gap-4'
    >
      <p className='text-muted-foreground line-clamp-3 text-sm leading-relaxed'>
        {project.description}
      </p>
      <div className='grid grid-cols-2 gap-2 sm:grid-cols-3'>
        <Metric
          label={t('Reward per fix')}
          value={formatQuota(project.reward_quota)}
        />
        <Metric
          label={t('Available slots')}
          value={`${slots}/${project.reward_slots}`}
        />
        <Metric
          label={t('Promotion spend')}
          value={formatQuota(project.promotion_quota)}
        />
      </div>
      <div className='mt-auto flex flex-wrap gap-2'>
        <Button
          variant='outline'
          render={
            <a href={project.repository_url} target='_blank' rel='noreferrer' />
          }
        >
          <HugeiconsIcon
            icon={GithubIcon}
            strokeWidth={2}
            data-icon='inline-start'
          />
          {t('Repository')}
          <HugeiconsIcon
            icon={ExternalLinkIcon}
            strokeWidth={2}
            data-icon='inline-end'
          />
        </Button>
        {viewerAction}
      </div>
    </TitledCard>
  )
}

function OwnerProjectCard(props: {
  project: BountyProject
  pending: string
  onEdit: () => void
  onReview: () => void
  onPublish: () => void
  onPause: () => void
  onResume: () => void
  onClose: () => void
  onDelete: () => void
}) {
  const { t } = useTranslation()
  const { project } = props
  const busy = props.pending !== ''
  return (
    <TitledCard
      title={project.title}
      description={project.repository_url}
      icon={<HugeiconsIcon icon={SourceCodeIcon} strokeWidth={1.8} />}
      iconTone='info'
      disableHoverEffect
      action={<Badge variant='outline'>{statusLabel(t, project.status)}</Badge>}
    >
      <div className='flex flex-col gap-4'>
        <div className='grid gap-2 sm:grid-cols-4'>
          <Metric
            label={t('Promotion spend')}
            value={formatQuota(project.promotion_quota)}
          />
          <Metric
            label={t('Reward per fix')}
            value={formatQuota(project.reward_quota)}
          />
          <Metric
            label={t('Escrow remaining')}
            value={formatQuota(project.escrow_quota)}
          />
          <Metric
            label={t('Challenges')}
            value={`${project.active_challenge_count} / ${project.approved_challenge_count}`}
          />
        </div>
        <div className='flex flex-wrap gap-2'>
          {project.status === 'draft' && (
            <>
              <Button variant='outline' onClick={props.onEdit} disabled={busy}>
                <HugeiconsIcon
                  icon={FileEditIcon}
                  strokeWidth={2}
                  data-icon='inline-start'
                />
                {t('Edit')}
              </Button>
              <Button onClick={props.onPublish} disabled={busy}>
                <HugeiconsIcon
                  icon={PlayIcon}
                  strokeWidth={2}
                  data-icon='inline-start'
                />
                {t('Publish and fund')}
              </Button>
              <Button
                variant='destructive'
                onClick={props.onDelete}
                disabled={busy}
              >
                <HugeiconsIcon
                  icon={Delete02Icon}
                  strokeWidth={2}
                  data-icon='inline-start'
                />
                {t('Delete')}
              </Button>
            </>
          )}
          {(project.status === 'published' || project.status === 'paused') && (
            <>
              <Button
                variant='outline'
                onClick={props.onReview}
                disabled={busy}
              >
                {t('Review submissions')}
              </Button>
              {project.status === 'published' ? (
                <Button
                  variant='outline'
                  onClick={props.onPause}
                  disabled={busy}
                >
                  <HugeiconsIcon
                    icon={PauseIcon}
                    strokeWidth={2}
                    data-icon='inline-start'
                  />
                  {t('Pause')}
                </Button>
              ) : (
                <Button
                  variant='outline'
                  onClick={props.onResume}
                  disabled={busy}
                >
                  <HugeiconsIcon
                    icon={PlayIcon}
                    strokeWidth={2}
                    data-icon='inline-start'
                  />
                  {t('Resume')}
                </Button>
              )}
              <Button
                variant='destructive'
                onClick={props.onClose}
                disabled={busy}
              >
                <HugeiconsIcon
                  icon={CancelCircleIcon}
                  strokeWidth={2}
                  data-icon='inline-start'
                />
                {t('Close and refund escrow')}
              </Button>
            </>
          )}
          {(project.status === 'completed' || project.status === 'closed') && (
            <Button variant='outline' onClick={props.onReview} disabled={busy}>
              {t('View lifecycle')}
            </Button>
          )}
        </div>
      </div>
    </TitledCard>
  )
}

function ChallengeCard({
  challenge,
  pending,
  onSubmit,
  onWithdraw,
}: {
  challenge: BountyChallenge
  pending: string
  onSubmit: () => void
  onWithdraw: () => void
}) {
  const { t } = useTranslation()
  const actionable = challenge.status === 'accepted'
  const withdrawable =
    challenge.status === 'accepted' || challenge.status === 'submitted'
  return (
    <TitledCard
      title={challenge.project_title || t('Bounty challenge')}
      description={`${challenge.owner_username ?? ''} · ${statusLabel(t, challenge.status)}`}
      icon={<HugeiconsIcon icon={Bug01Icon} strokeWidth={1.8} />}
      iconTone='neutral'
      disableHoverEffect
    >
      <div className='flex flex-col gap-4'>
        <Metric
          label={t('Locked reward')}
          value={formatQuota(challenge.reward_quota)}
        />
        {challenge.review_note && (
          <p className='text-muted-foreground text-sm'>
            {challenge.review_note}
          </p>
        )}
        <div className='flex flex-wrap gap-2'>
          {challenge.repository_url && (
            <Button
              variant='outline'
              render={
                <a
                  href={challenge.repository_url}
                  target='_blank'
                  rel='noreferrer'
                />
              }
            >
              {t('Repository')}
              <HugeiconsIcon
                icon={ExternalLinkIcon}
                strokeWidth={2}
                data-icon='inline-end'
              />
            </Button>
          )}
          {actionable && <Button onClick={onSubmit}>{t('Submit work')}</Button>}
          {withdrawable && (
            <Button
              variant='outline'
              onClick={onWithdraw}
              disabled={pending !== ''}
            >
              {t('Withdraw')}
            </Button>
          )}
        </div>
      </div>
    </TitledCard>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className='bg-muted/50 rounded-lg border p-3'>
      <p className='text-muted-foreground text-xs'>{label}</p>
      <p className='mt-1 text-sm font-semibold'>{value}</p>
    </div>
  )
}

function DraftDialog(props: {
  open: boolean
  onOpenChange: (open: boolean) => void
  editing: boolean
  draft: DraftForm
  setDraft: (draft: DraftForm) => void
  totalQuota: number
  availableQuota: number
  pending: boolean
  onSave: () => void
}) {
  const { t } = useTranslation()
  const update = <K extends keyof DraftForm>(key: K, value: DraftForm[K]) =>
    props.setDraft({ ...props.draft, [key]: value })
  return (
    <Dialog
      open={props.open}
      onOpenChange={props.onOpenChange}
      title={props.editing ? t('Edit bounty draft') : t('Create bounty')}
      description={t(
        'Drafts are free. Your balance is charged only when you publish.'
      )}
      contentClassName='sm:max-w-2xl'
      contentHeight='min(70vh, 760px)'
      bodyClassName='flex flex-col gap-4'
      footer={
        <>
          <Button
            variant='outline'
            onClick={() => props.onOpenChange(false)}
            disabled={props.pending}
          >
            {t('Cancel')}
          </Button>
          <Button onClick={props.onSave} disabled={props.pending}>
            {props.editing ? t('Save changes') : t('Save draft')}
          </Button>
        </>
      }
    >
      <Field label={t('GitHub repository URL')} htmlFor='bounty-repository'>
        <Input
          id='bounty-repository'
          value={props.draft.repositoryUrl}
          onChange={(e) => update('repositoryUrl', e.target.value)}
          placeholder='https://github.com/owner/repository'
        />
      </Field>
      <Field label={t('Bounty title')} htmlFor='bounty-title'>
        <Input
          id='bounty-title'
          value={props.draft.title}
          onChange={(e) => update('title', e.target.value)}
        />
      </Field>
      <Field label={t('Project and defect scope')} htmlFor='bounty-description'>
        <Textarea
          id='bounty-description'
          rows={4}
          value={props.draft.description}
          onChange={(e) => update('description', e.target.value)}
        />
      </Field>
      <Field
        label={t('Acceptance and verification rules')}
        htmlFor='bounty-rules'
      >
        <Textarea
          id='bounty-rules'
          rows={7}
          value={props.draft.rules}
          onChange={(e) => update('rules', e.target.value)}
          placeholder={t(
            'Describe eligible defects, required tests, review criteria, and exclusions.'
          )}
        />
      </Field>
      <div className='grid gap-4 sm:grid-cols-3'>
        <Field label={t('Promotion spend')} htmlFor='bounty-promotion'>
          <Input
            id='bounty-promotion'
            type='number'
            min={0}
            value={props.draft.promotionAmount}
            onChange={(e) => update('promotionAmount', Number(e.target.value))}
          />
        </Field>
        <Field label={t('Reward per fix')} htmlFor='bounty-reward'>
          <Input
            id='bounty-reward'
            type='number'
            min={0}
            value={props.draft.rewardAmount}
            onChange={(e) => update('rewardAmount', Number(e.target.value))}
          />
        </Field>
        <Field label={t('Reward slots')} htmlFor='bounty-slots'>
          <Input
            id='bounty-slots'
            type='number'
            min={1}
            max={100}
            value={props.draft.rewardSlots}
            onChange={(e) => update('rewardSlots', Number(e.target.value))}
          />
        </Field>
      </div>
      <Alert>
        <HugeiconsIcon icon={MoneyLockIcon} strokeWidth={2} />
        <AlertTitle>{t('Publish charge')}</AlertTitle>
        <AlertDescription>
          {t(
            'Total charged on publish: {{total}}. Current balance: {{balance}}.',
            {
              total: formatQuota(props.totalQuota),
              balance: formatQuota(props.availableQuota),
            }
          )}
        </AlertDescription>
      </Alert>
    </Dialog>
  )
}

function Field({
  label,
  htmlFor,
  children,
}: {
  label: string
  htmlFor: string
  children: React.ReactNode
}) {
  return (
    <div className='flex flex-col gap-2'>
      <Label htmlFor={htmlFor}>{label}</Label>
      {children}
    </div>
  )
}

function SubmissionDialog(props: {
  target: { projectId: number; challenge: BountyChallenge } | null
  onOpenChange: (open: boolean) => void
  submission: {
    issueUrl: string
    pullRequestUrl: string
    encryptedReviewMessage: string
    submissionNote: string
  }
  setSubmission: (value: {
    issueUrl: string
    pullRequestUrl: string
    encryptedReviewMessage: string
    submissionNote: string
  }) => void
  pending: boolean
  onSubmit: () => void
}) {
  const { t } = useTranslation()
  const update = (key: keyof typeof props.submission, value: string) =>
    props.setSubmission({ ...props.submission, [key]: value })
  return (
    <Dialog
      open={Boolean(props.target)}
      onOpenChange={props.onOpenChange}
      title={t('Submit bounty work')}
      description={t(
        'Submit matching GitHub evidence and the LIghtJUNction encrypted review message used for verification.'
      )}
      contentClassName='sm:max-w-2xl'
      footer={
        <>
          <Button
            variant='outline'
            onClick={() => props.onOpenChange(false)}
            disabled={props.pending}
          >
            {t('Cancel')}
          </Button>
          <Button onClick={props.onSubmit} disabled={props.pending}>
            {t('Submit for review')}
          </Button>
        </>
      }
    >
      <div className='flex flex-col gap-4 py-2'>
        <Field label={t('GitHub Issue URL')} htmlFor='bounty-issue-url'>
          <Input
            id='bounty-issue-url'
            value={props.submission.issueUrl}
            onChange={(e) => update('issueUrl', e.target.value)}
          />
        </Field>
        <Field label={t('GitHub pull request URL')} htmlFor='bounty-pr-url'>
          <Input
            id='bounty-pr-url'
            value={props.submission.pullRequestUrl}
            onChange={(e) => update('pullRequestUrl', e.target.value)}
          />
        </Field>
        <Field
          label={t('Encrypted review message')}
          htmlFor='bounty-encrypted-message'
        >
          <Textarea
            id='bounty-encrypted-message'
            rows={5}
            value={props.submission.encryptedReviewMessage}
            onChange={(e) => update('encryptedReviewMessage', e.target.value)}
          />
        </Field>
        <Field
          label={t('Submission note (optional)')}
          htmlFor='bounty-submission-note'
        >
          <Textarea
            id='bounty-submission-note'
            rows={4}
            value={props.submission.submissionNote}
            onChange={(e) => update('submissionNote', e.target.value)}
          />
        </Field>
      </div>
    </Dialog>
  )
}

function ProjectReviewDialog(props: {
  open: boolean
  onOpenChange: (open: boolean) => void
  detail: BountyProjectDetail | null
  pending: string
  onReview: (challenge: BountyChallenge, action: 'approve' | 'reject') => void
}) {
  const { t } = useTranslation()
  return (
    <Dialog
      open={props.open}
      onOpenChange={props.onOpenChange}
      title={props.detail?.project.title ?? t('Bounty lifecycle')}
      description={t(
        'Review participants, evidence, balance transfers, and escrow history.'
      )}
      contentClassName='sm:max-w-3xl'
      contentHeight='min(72vh, 820px)'
    >
      <div className='flex flex-col gap-4'>
        {(props.detail?.challenges.length ?? 0) === 0 ? (
          <Empty className='min-h-48 border'>
            <EmptyHeader>
              <EmptyTitle>{t('No challenge activity yet')}</EmptyTitle>
              <EmptyDescription>
                {t('Accepted challenges and submissions will appear here.')}
              </EmptyDescription>
            </EmptyHeader>
          </Empty>
        ) : (
          props.detail?.challenges.map((challenge) => (
            <div
              key={challenge.id}
              className='flex flex-col gap-3 rounded-xl border p-4'
            >
              <div className='flex flex-wrap items-start justify-between gap-2'>
                <div>
                  <p className='font-medium'>@{challenge.github_handle}</p>
                  <p className='text-muted-foreground text-xs'>
                    {challenge.participant_username}
                  </p>
                </div>
                <Badge variant='outline'>
                  {statusLabel(t, challenge.status)}
                </Badge>
              </div>
              {(challenge.issue_url || challenge.pull_request_url) && (
                <div className='flex flex-wrap gap-2'>
                  {challenge.issue_url && (
                    <Button
                      variant='outline'
                      render={
                        <a
                          href={challenge.issue_url}
                          target='_blank'
                          rel='noreferrer'
                        />
                      }
                    >
                      {t('Issue')}
                      <HugeiconsIcon
                        icon={ExternalLinkIcon}
                        strokeWidth={2}
                        data-icon='inline-end'
                      />
                    </Button>
                  )}
                  {challenge.pull_request_url && (
                    <Button
                      variant='outline'
                      render={
                        <a
                          href={challenge.pull_request_url}
                          target='_blank'
                          rel='noreferrer'
                        />
                      }
                    >
                      {t('Pull request')}
                      <HugeiconsIcon
                        icon={ExternalLinkIcon}
                        strokeWidth={2}
                        data-icon='inline-end'
                      />
                    </Button>
                  )}
                </div>
              )}
              {challenge.encrypted_review_message && (
                <p className='bg-muted/50 rounded-lg border p-3 text-sm whitespace-pre-wrap'>
                  {challenge.encrypted_review_message}
                </p>
              )}
              {challenge.review_note && (
                <p className='text-muted-foreground text-sm'>
                  {challenge.review_note}
                </p>
              )}
              {challenge.status === 'submitted' && (
                <div className='flex flex-wrap gap-2'>
                  <Button
                    onClick={() => props.onReview(challenge, 'approve')}
                    disabled={props.pending !== ''}
                  >
                    <HugeiconsIcon
                      icon={CheckmarkCircle02Icon}
                      strokeWidth={2}
                      data-icon='inline-start'
                    />
                    {t('Approve and pay')} {formatQuota(challenge.reward_quota)}
                  </Button>
                  <Button
                    variant='destructive'
                    onClick={() => props.onReview(challenge, 'reject')}
                    disabled={props.pending !== ''}
                  >
                    {t('Reject')}
                  </Button>
                </div>
              )}
            </div>
          ))
        )}
        {(props.detail?.ledger.length ?? 0) > 0 && (
          <>
            <Separator />
            <div className='flex flex-col gap-2'>
              <h3 className='font-semibold'>{t('Balance ledger')}</h3>
              {props.detail?.ledger.map((entry) => (
                <div
                  key={entry.id}
                  className='flex items-center justify-between gap-4 rounded-lg border px-3 py-2 text-sm'
                >
                  <span>{t(entry.kind)}</span>
                  <span className='font-medium'>
                    {formatQuota(entry.quota)}
                  </span>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </Dialog>
  )
}

function RulesPanel() {
  const { t } = useTranslation()
  const steps = [
    [
      '1',
      'Find and document a real bug',
      'Open a valid Issue with the affected project, reproducible steps, expected behavior, actual behavior, and impact.',
    ],
    [
      '2',
      'Submit a focused fix',
      'Open a pull request that links the Issue and includes appropriate verification or tests.',
    ],
    [
      '3',
      'Send encrypted review details',
      'Open the LIghtJUNction encrypted channel. Include your handle plus the Issue and PR links, and use GitHub Issue to create the encrypted review message.',
    ],
    [
      '4',
      'Email the review links',
      'Email lightjunction.me@gmail.com with the Issue and PR links so the contribution is ready for review.',
    ],
    [
      '5',
      'Submit and wait for review',
      'Submit the evidence in Open-source bounties. The project owner verifies the defect and fix before approving payment.',
    ],
  ] as const
  return (
    <div className='grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]'>
      <TitledCard
        title={t('Real bug-fix contribution rewards')}
        description={t(
          'A separate incentive for genuine defects in public projects. It is not part of the Challenge II recovery process.'
        )}
        icon={<HugeiconsIcon icon={Bug01Icon} strokeWidth={1.8} />}
        iconTone='primary'
        disableHoverEffect
      >
        <div className='grid gap-3 sm:grid-cols-2'>
          {steps.map(([number, title, description]) => (
            <div key={number} className='flex gap-3 rounded-xl border p-4'>
              <Badge variant='secondary'>{number}</Badge>
              <div>
                <h3 className='font-semibold'>{t(title)}</h3>
                <p className='text-muted-foreground mt-1 text-sm leading-relaxed'>
                  {t(description)}
                </p>
              </div>
            </div>
          ))}
        </div>
      </TitledCard>
      <TitledCard
        title={t('Quality requirements')}
        description={t('Only genuine, reviewable engineering work qualifies.')}
        icon={<HugeiconsIcon icon={Award01Icon} strokeWidth={1.8} />}
        iconTone='neutral'
        disableHoverEffect
      >
        <div className='flex flex-col gap-4'>
          <p className='text-muted-foreground text-sm leading-relaxed'>
            {t(
              'Low-quality reports, fabricated bugs, duplicate Issues, unrelated pull requests, mechanical spam, and changes made only to obtain a reward do not qualify.'
            )}
          </p>
          <Separator />
          <p className='text-sm font-medium'>
            {t(
              'Approved submissions transfer the locked reward directly to the contributor balance for use with supported models.'
            )}
          </p>
        </div>
      </TitledCard>
    </div>
  )
}
