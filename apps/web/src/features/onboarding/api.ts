import { api } from '@/lib/api'

export type DeveloperAccessRequest = {
  id: number
  status: 'pending' | 'approved' | 'rejected'
  reason: string
  admin_note: string
  created_at: number
  reviewed_at: number
}

type ApiEnvelope<T> = {
  success: boolean
  code?: string
  message?: string
  data: T
}

async function unwrap<T>(request: Promise<{ data: ApiEnvelope<T> }>) {
  const response = await request
  if (!response.data.success) {
    const error = new Error(
      response.data.message || 'Developer access request failed'
    )
    Object.assign(error, { code: response.data.code })
    throw error
  }
  return response.data.data
}

export function getDeveloperAccessRequest() {
  return unwrap<DeveloperAccessRequest | null>(
    api.get('/api/user/developer-access/request', {
      skipBusinessError: true,
      skipErrorHandler: true,
    })
  )
}

export function submitDeveloperAccessRequest(reason: string) {
  return unwrap<DeveloperAccessRequest>(
    api.post('/api/user/developer-access/request', { reason })
  )
}
