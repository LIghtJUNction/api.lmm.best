import { Link } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Textarea } from '@/components/ui/textarea'
import {
  getDeveloperAccessRequest,
  submitDeveloperAccessRequest,
  type DeveloperAccessRequest,
} from '@/features/onboarding/api'

export function AssistantActivationTool() {
  const { t } = useTranslation()
  const [request, setRequest] = useState<DeveloperAccessRequest | null>(null)
  const [reason, setReason] = useState('')
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    void getDeveloperAccessRequest()
      .then(setRequest)
      .catch(() => undefined)
  }, [])

  const submit = async () => {
    if (loading || request?.status === 'pending') return
    setLoading(true)
    try {
      setRequest(await submitDeveloperAccessRequest(reason.trim()))
      setReason('')
      toast.success(t('Unlock request submitted'))
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : t('Unable to submit unlock request')
      )
    } finally {
      setLoading(false)
    }
  }

  return (
    <Card size='sm' className='border-primary/30 bg-primary/5'>
      <CardHeader>
        <CardTitle>{t('Unlock L1 access')}</CardTitle>
        <CardDescription>
          {t(
            'Add funds for automatic activation, or send a free explanation to an administrator for manual review.'
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className='grid gap-3'>
        <Button variant='outline' render={<Link to='/wallet' />}>
          {t('Open recharge and plans')}
        </Button>
        {request?.status === 'pending' ? (
          <p className='text-muted-foreground text-xs leading-5'>
            {t('Your free unlock request is waiting for administrator review.')}
          </p>
        ) : (
          <>
            <Textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              rows={4}
              maxLength={2000}
              placeholder={t(
                'Write a short explanation of what you want to build or why you need L1 access.'
              )}
            />
            <Button
              type='button'
              onClick={() => void submit()}
              disabled={loading}
            >
              {loading ? t('Submitting...') : t('Send free review request')}
            </Button>
          </>
        )}
      </CardContent>
    </Card>
  )
}
