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
import { ArrowRight, KeyRound, LoaderCircle, ShieldCheck } from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { CopyButton } from '@/components/copy-button'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'

import { createAssistantDefaultKey, type AssistantCreatedKey } from './api'

function ConnectionValue(props: {
  label: string
  value: string
  secret?: boolean
}) {
  return (
    <div className='flex items-center justify-between gap-2 py-2'>
      <span className='text-muted-foreground shrink-0 text-xs'>
        {props.label}
      </span>
      <div className='flex min-w-0 items-center gap-1.5'>
        <code
          className={
            props.secret
              ? 'min-w-0 flex-1 text-xs break-all'
              : 'min-w-0 flex-1 truncate text-xs'
          }
        >
          {props.value}
        </code>
        <CopyButton value={props.value} size='sm' />
      </div>
    </div>
  )
}

function ConnectionDetails(props: {
  baseUrl: string
  model: string
  apiKey?: string
}) {
  const { t } = useTranslation()
  return (
    <div className='rounded-lg border px-3'>
      <ConnectionValue label={t('Base URL')} value={props.baseUrl} />
      <Separator />
      <ConnectionValue label={t('Model ID')} value={props.model} />
      {props.apiKey ? (
        <>
          <Separator />
          <ConnectionValue label={t('API key')} value={props.apiKey} secret />
        </>
      ) : null}
    </div>
  )
}

export function AssistantKeyTool(props: {
  baseUrl: string
  defaultModel: string
  developerAccessGranted: boolean
}) {
  const { t } = useTranslation()
  const [name, setName] = useState(t('AI assistant key'))
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [created, setCreated] = useState<AssistantCreatedKey | null>(null)
  const model = props.defaultModel || '<MODEL_ID>'

  const createKey = async () => {
    if (creating) return
    setCreating(true)
    try {
      const result = await createAssistantDefaultKey(name.trim())
      setCreated(result)
      setConfirmOpen(false)
      toast.success(t('API key created'))
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : t('Unable to create API key')
      )
    } finally {
      setCreating(false)
    }
  }

  if (created) {
    return (
      <Card size='sm' className='border-success/40 bg-success/5'>
        <CardHeader>
          <CardTitle className='flex items-center gap-2'>
            <ShieldCheck className='text-success size-4' aria-hidden='true' />
            {t('API key created')}
          </CardTitle>
          <CardDescription>
            {t('Copy the key now and store it somewhere secure.')}
          </CardDescription>
        </CardHeader>
        <CardContent className='grid gap-3'>
          <ConnectionDetails
            baseUrl={props.baseUrl}
            model={model}
            apiKey={created.key}
          />
        </CardContent>
      </Card>
    )
  }

  return (
    <>
      <Card size='sm'>
        <CardHeader>
          <CardTitle>
            {props.developerAccessGranted
              ? t('Create a default API key')
              : t('Connection details')}
          </CardTitle>
          <CardDescription>
            {t(
              'Base URL tells your client where to connect, Model ID selects the model, and an API key is the secret credential sent with each request.'
            )}
          </CardDescription>
        </CardHeader>
        <CardContent className='grid gap-3'>
          <ConnectionDetails baseUrl={props.baseUrl} model={model} />
          {props.developerAccessGranted ? (
            <>
              <p className='text-muted-foreground text-xs leading-5'>
                {t(
                  'This creates one unlimited, non-expiring key. Your wallet balance still limits actual usage.'
                )}
              </p>
              <div className='grid gap-1.5'>
                <Label htmlFor='assistant-key-name'>{t('Key name')}</Label>
                <Input
                  id='assistant-key-name'
                  value={name}
                  maxLength={50}
                  autoComplete='off'
                  onChange={(event) => setName(event.target.value)}
                />
              </div>
              <Button
                type='button'
                onClick={() => setConfirmOpen(true)}
                disabled={!name.trim()}
              >
                <KeyRound data-icon='inline-start' aria-hidden='true' />
                {t('Review key creation')}
              </Button>
            </>
          ) : (
            <div className='grid gap-3 rounded-lg border border-dashed p-3'>
              <div>
                <p className='text-xs font-medium'>
                  {t('API key creation requires L1')}
                </p>
                <p className='text-muted-foreground mt-1 text-xs leading-5'>
                  {t(
                    'Only L0 is restricted. Ask an administrator to approve L1, then return here to create a key.'
                  )}
                </p>
              </div>
              <Button
                variant='outline'
                size='sm'
                render={<Link to='/getting-started' />}
              >
                {t('View onboarding status')}
                <ArrowRight data-icon='inline-end' aria-hidden='true' />
              </Button>
            </div>
          )}
        </CardContent>
      </Card>

      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t('Create this API key?')}</AlertDialogTitle>
            <AlertDialogDescription>
              {t(
                'A new credential named “{{name}}” will be added to your account. Confirm only if you requested this action.',
                { name: name.trim() }
              )}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={creating}>
              {t('Cancel')}
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={() => void createKey()}
              disabled={creating}
            >
              {creating ? (
                <LoaderCircle className='animate-spin' aria-hidden='true' />
              ) : null}
              {t('Confirm and create')}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
