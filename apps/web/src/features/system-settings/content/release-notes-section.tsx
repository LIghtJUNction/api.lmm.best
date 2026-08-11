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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  HistoryIcon,
  MegaphoneIcon,
  RotateCcwIcon,
  SendIcon,
} from 'lucide-react'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Markdown } from '@/components/ui/markdown'
import { Textarea } from '@/components/ui/textarea'
import {
  listReleaseNotes,
  publishReleaseNote,
} from '@/features/release-notes/api'
import type { ReleaseNote } from '@/features/release-notes/types'
import { formatTimestampToDate } from '@/lib/format'

import { SettingsSection } from '../components/settings-section'

const releaseHistoryQueryKey = ['release-notes', 'admin', 'history'] as const

export function ReleaseNotesSection() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [version, setVersion] = useState('')
  const [content, setContent] = useState('')

  const historyQuery = useQuery({
    queryKey: releaseHistoryQueryKey,
    queryFn: listReleaseNotes,
  })
  const publishMutation = useMutation({
    mutationFn: publishReleaseNote,
    onSuccess: async (note) => {
      setVersion(note.version)
      setContent('')
      toast.success(
        t('Version {{version}} revision {{revision}} published', {
          version: note.version,
          revision: note.revision,
        })
      )
      await queryClient.invalidateQueries({ queryKey: releaseHistoryQueryKey })
    },
    onError: (error: Error) => toast.error(error.message),
  })

  const handlePublish = () => {
    const normalizedVersion = version.trim()
    const normalizedContent = content.trim()
    if (!normalizedVersion) {
      toast.error(t('Version is required'))
      return
    }
    if (!normalizedContent) {
      toast.error(t('Changelog is required'))
      return
    }
    publishMutation.mutate({
      version: normalizedVersion,
      content: normalizedContent,
    })
  }

  const prepareRevision = (note: ReleaseNote) => {
    setVersion(note.version)
    setContent(note.content)
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const notes = historyQuery.data ?? []
  let historyContent: ReactNode
  if (historyQuery.isLoading) {
    historyContent = (
      <p className='text-muted-foreground text-sm'>
        {t('Loading release history...')}
      </p>
    )
  } else if (historyQuery.isError) {
    historyContent = (
      <div className='flex items-center justify-between gap-3 border p-3'>
        <p className='text-destructive text-sm'>
          {t('Failed to load release history')}
        </p>
        <Button
          type='button'
          variant='outline'
          size='sm'
          onClick={() => historyQuery.refetch()}
        >
          {t('Retry')}
        </Button>
      </div>
    )
  } else if (notes.length === 0) {
    historyContent = (
      <p className='text-muted-foreground border p-4 text-sm'>
        {t('No version updates have been published yet.')}
      </p>
    )
  } else {
    historyContent = notes.map((note) => (
      <Card key={note.id} size='sm' data-card-hover='false'>
        <CardHeader>
          <CardTitle className='flex flex-wrap items-center gap-2'>
            <span>{note.version}</span>
            <Badge variant='outline'>
              {t('Revision {{revision}}', {
                revision: note.revision,
              })}
            </Badge>
          </CardTitle>
          <CardDescription>
            {t('Published {{date}}', {
              date: formatTimestampToDate(note.published_at),
            })}
          </CardDescription>
          <CardAction>
            <Button
              type='button'
              variant='outline'
              size='sm'
              onClick={() => prepareRevision(note)}
            >
              <RotateCcwIcon className='size-4' />
              {t('Revise')}
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className='max-h-52 overflow-y-auto border-t pt-3'>
          <Markdown>{note.content}</Markdown>
        </CardContent>
      </Card>
    ))
  }

  return (
    <SettingsSection title={t('Version updates')}>
      <div className='space-y-4'>
        <Card>
          <CardHeader>
            <CardTitle className='flex items-center gap-2'>
              <MegaphoneIcon className='size-4' />
              {t('Publish version update')}
            </CardTitle>
            <CardDescription>
              {t(
                'Every released version must include a version number and changelog. Users will see it after their next login.'
              )}
            </CardDescription>
          </CardHeader>
          <CardContent className='grid gap-6 lg:grid-cols-2'>
            <div className='space-y-4'>
              <div className='space-y-2'>
                <Label htmlFor='release-version'>{t('Version')}</Label>
                <Input
                  id='release-version'
                  value={version}
                  maxLength={128}
                  placeholder='v1.2.3'
                  onChange={(event) => setVersion(event.target.value)}
                />
              </div>
              <div className='space-y-2'>
                <Label htmlFor='release-changelog'>{t('Changelog')}</Label>
                <Textarea
                  id='release-changelog'
                  value={content}
                  maxLength={20000}
                  rows={14}
                  placeholder={t(
                    'Describe user-visible changes, fixes, and important upgrade notes. Markdown is supported.'
                  )}
                  onChange={(event) => setContent(event.target.value)}
                />
                <p className='text-muted-foreground text-xs'>
                  {t('{{count}} / 20000 characters', {
                    count: [...content].length,
                  })}
                </p>
              </div>
              <Button
                type='button'
                disabled={publishMutation.isPending}
                onClick={handlePublish}
              >
                <SendIcon className='size-4' />
                {publishMutation.isPending
                  ? t('Publishing...')
                  : t('Publish update')}
              </Button>
            </div>
            <div className='space-y-2'>
              <Label>{t('Preview')}</Label>
              <div className='bg-muted/20 min-h-80 border p-4'>
                <div className='mb-4 flex flex-wrap items-center gap-2'>
                  <span className='font-semibold'>
                    {version.trim() || t('Version preview')}
                  </span>
                  <Badge variant='secondary'>{t('Unpublished')}</Badge>
                </div>
                {content.trim() ? (
                  <Markdown>{content}</Markdown>
                ) : (
                  <p className='text-muted-foreground text-sm'>
                    {t('Enter a changelog to preview it here.')}
                  </p>
                )}
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className='flex items-center gap-2'>
              <HistoryIcon className='size-4' />
              {t('Release history')}
            </CardTitle>
            <CardDescription>
              {t(
                'Publishing the same version again creates a new revision and notifies users again on their next login.'
              )}
            </CardDescription>
          </CardHeader>
          <CardContent className='space-y-3'>{historyContent}</CardContent>
        </Card>
      </div>
    </SettingsSection>
  )
}
