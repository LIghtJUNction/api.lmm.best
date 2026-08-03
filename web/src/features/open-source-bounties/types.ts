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
export type BountyProjectStatus =
  | 'draft'
  | 'published'
  | 'paused'
  | 'completed'
  | 'closed'

export type BountyChallengeStatus =
  | 'accepted'
  | 'submitted'
  | 'approved'
  | 'rejected'
  | 'withdrawn'

export interface BountyChallenge {
  id: number
  project_id: number
  participant_user_id: number
  participant_username?: string
  github_handle: string
  status: BountyChallengeStatus
  issue_url: string
  pull_request_url: string
  encrypted_review_message: string
  submission_note: string
  review_note: string
  reward_quota: number
  accepted_at: number
  submitted_at: number
  reviewed_at: number
  paid_at: number
  project_title?: string
  repository_url?: string
  owner_username?: string
}

export interface BountyProject {
  id: number
  owner_user_id: number
  owner_username: string
  repository_url: string
  title: string
  description: string
  rules: string
  promotion_quota: number
  reward_quota: number
  reward_slots: number
  escrow_quota: number
  status: BountyProjectStatus
  created_at: number
  updated_at: number
  published_at: number
  closed_at: number
  active_challenge_count: number
  approved_challenge_count: number
  viewer_challenge?: BountyChallenge
}

export interface BountyDraftInput {
  repository_url: string
  title: string
  description: string
  rules: string
  promotion_quota: number
  reward_quota: number
  reward_slots: number
}

export interface BountyProjectDetail {
  project: BountyProject
  challenges: BountyChallenge[]
  ledger: Array<{
    id: number
    project_id: number
    challenge_id: number
    user_id: number
    counterparty_user_id: number
    kind: string
    quota: number
    created_at: number
  }>
}
