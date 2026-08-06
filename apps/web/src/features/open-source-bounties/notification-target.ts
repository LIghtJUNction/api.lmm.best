import {
  Award01Icon,
  GiftIcon,
  JusticeScale01Icon,
} from '@hugeicons/core-free-icons'
import type { TFunction } from 'i18next'

import type { BountyNotification, BountyProjectDetail } from './types'

export interface BountyNotificationDetailTarget {
  projectId: number
  challengeId: number
}

export function selectBountyNotificationChallenge(
  detail: BountyProjectDetail,
  target: BountyNotificationDetailTarget
) {
  if (detail.project.id !== target.projectId) return null
  return (
    detail.challenges.find(
      (challenge) =>
        challenge.id === target.challengeId &&
        challenge.project_id === target.projectId
    ) ?? null
  )
}

export function bountyNotificationPresentation(
  item: BountyNotification,
  t: TFunction
) {
  if (item.kind === 'tip_transfer') {
    return {
      icon: GiftIcon,
      message: t('sent you a tip of'),
      showNoteAndThank: true,
    }
  }
  if (item.kind === 'dispute_reward_transfer') {
    return {
      icon: JusticeScale01Icon,
      message: t('paid your bounty reward after dispute resolution'),
      showNoteAndThank: false,
    }
  }
  return {
    icon: Award01Icon,
    message: t('approved and paid your bounty reward'),
    showNoteAndThank: false,
  }
}

export function bountyNotificationSearch(item: BountyNotification) {
  return { projectId: item.project_id, challengeId: item.challenge_id }
}
