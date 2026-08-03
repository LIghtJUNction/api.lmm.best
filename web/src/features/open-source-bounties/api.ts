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
import { api } from '@/lib/api'

import type {
  BountyChallenge,
  BountyDraftInput,
  BountyProject,
  BountyProjectDetail,
} from './types'

interface ApiEnvelope<T> {
  success: boolean
  code?: string
  message?: string
  data: T
}

async function unwrap<T>(request: Promise<{ data: ApiEnvelope<T> }>) {
  const response = await request
  if (!response.data.success) {
    const error = new Error(
      response.data.message || 'Open-source bounty request failed'
    )
    Object.assign(error, { code: response.data.code })
    throw error
  }
  return response.data.data
}

export function listBounties() {
  return unwrap<{ items: BountyProject[]; total: number }>(
    api.get('/api/open-source-bounties?page=1&page_size=50')
  )
}

export function listOwnedBounties() {
  return unwrap<BountyProject[]>(api.get('/api/open-source-bounties/mine'))
}

export function listAcceptedBounties() {
  return unwrap<BountyChallenge[]>(
    api.get('/api/open-source-bounties/accepted')
  )
}

export function getBountyDetail(projectId: number) {
  return unwrap<BountyProjectDetail>(
    api.get(`/api/open-source-bounties/projects/${projectId}`)
  )
}

export function createBounty(input: BountyDraftInput) {
  return unwrap<BountyProject>(api.post('/api/open-source-bounties', input))
}

export function updateBounty(projectId: number, input: BountyDraftInput) {
  return unwrap<BountyProject>(
    api.put(`/api/open-source-bounties/projects/${projectId}`, input)
  )
}

export function deleteBounty(projectId: number) {
  return unwrap<null>(
    api.delete(`/api/open-source-bounties/projects/${projectId}`)
  )
}

export function publishBounty(projectId: number) {
  return unwrap<{ project: BountyProject; charged_quota: number }>(
    api.post(`/api/open-source-bounties/projects/${projectId}/publish`)
  )
}

export function pauseBounty(projectId: number) {
  return unwrap<BountyProject>(
    api.post(`/api/open-source-bounties/projects/${projectId}/pause`)
  )
}

export function resumeBounty(projectId: number) {
  return unwrap<BountyProject>(
    api.post(`/api/open-source-bounties/projects/${projectId}/resume`)
  )
}

export function closeBounty(projectId: number) {
  return unwrap<{ project: BountyProject; refunded_quota: number }>(
    api.post(`/api/open-source-bounties/projects/${projectId}/close`)
  )
}

export function acceptBounty(projectId: number, githubHandle: string) {
  return unwrap<BountyChallenge>(
    api.post(`/api/open-source-bounties/projects/${projectId}/accept`, {
      github_handle: githubHandle,
    })
  )
}

export function submitChallenge(
  projectId: number,
  input: {
    issue_url: string
    pull_request_url: string
    encrypted_review_message: string
    submission_note: string
  }
) {
  return unwrap<BountyChallenge>(
    api.post(`/api/open-source-bounties/projects/${projectId}/submit`, input)
  )
}

export function withdrawChallenge(challengeId: number) {
  return unwrap<BountyChallenge>(
    api.post(`/api/open-source-bounties/challenges/${challengeId}/withdraw`)
  )
}

export function reviewChallenge(
  challengeId: number,
  action: 'approve' | 'reject',
  reviewNote: string
) {
  return unwrap<{ challenge: BountyChallenge; transferred_quota: number }>(
    api.post(`/api/open-source-bounties/challenges/${challengeId}/${action}`, {
      review_note: reviewNote,
    })
  )
}
