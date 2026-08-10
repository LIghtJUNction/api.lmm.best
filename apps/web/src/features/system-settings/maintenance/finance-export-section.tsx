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
  ClipboardCopyIcon,
  DownloadIcon,
  Loader2Icon,
  ShieldCheckIcon,
} from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { copyToClipboard } from '@/lib/copy-to-clipboard'

import { fetchFinanceExport } from '../api'
import { SettingsSection } from '../components/settings-section'

const exportWindowOptions = [7, 30, 90] as const

function isJsonBlob(blob: Blob) {
  return blob.type.includes('json') || blob.type.includes('text/html')
}

async function blobErrorMessage(blob: Blob, fallback: string) {
  if (!isJsonBlob(blob)) return fallback
  try {
    const payload = JSON.parse(await blob.text()) as { message?: string }
    return payload.message || fallback
  } catch {
    return fallback
  }
}

export function FinanceExportSection() {
  const { t } = useTranslation()
  const [days, setDays] = useState<(typeof exportWindowOptions)[number]>(30)
  const [busyAction, setBusyAction] = useState<'copy' | 'download' | null>(null)

  const runExport = async (action: 'copy' | 'download') => {
    setBusyAction(action)
    try {
      const response = await fetchFinanceExport(
        action === 'copy' ? 'text' : 'zip',
        days
      )
      const blob = response.data
      if (isJsonBlob(blob)) {
        throw new Error(
          await blobErrorMessage(blob, t('Finance export failed'))
        )
      }

      if (action === 'copy') {
        const copied = await copyToClipboard(await blob.text())
        if (!copied) throw new Error(t('Failed to copy to clipboard'))
        toast.success(t('Financial snapshot copied to clipboard'))
      } else {
        const url = URL.createObjectURL(blob)
        const link = document.createElement('a')
        link.href = url
        link.download = `lmm-finance-export-${days}d.zip`
        document.body.appendChild(link)
        link.click()
        link.remove()
        window.setTimeout(() => URL.revokeObjectURL(url), 1000)
        toast.success(t('Financial ZIP downloaded'))
      }
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : t('Finance export failed')
      )
    } finally {
      setBusyAction(null)
    }
  }

  return (
    <SettingsSection title={t('Financial data export')}>
      <div className='space-y-5'>
        <Alert>
          <ShieldCheckIcon />
          <AlertDescription>
            {t(
              'Exports include model prices, ratios, plans, user balances, channel pricing, and time-windowed billing records. Secrets, keys, provider payloads, IPs, request bodies, and opaque log fields are excluded.'
            )}
          </AlertDescription>
        </Alert>

        <div className='flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between'>
          <label className='flex min-w-40 flex-col gap-1.5 text-sm'>
            <span className='font-medium'>{t('Billing record window')}</span>
            <select
              className='border-input bg-background h-9 rounded-md border px-3 text-sm'
              value={days}
              onChange={(event) =>
                setDays(
                  Number(
                    event.target.value
                  ) as (typeof exportWindowOptions)[number]
                )
              }
              disabled={busyAction !== null}
            >
              {exportWindowOptions.map((option) => (
                <option key={option} value={option}>
                  {t('{{days}} days', { days: option })}
                </option>
              ))}
            </select>
          </label>

          <div className='flex flex-col gap-2 sm:flex-row'>
            <Button
              type='button'
              variant='outline'
              onClick={() => void runExport('copy')}
              disabled={busyAction !== null}
            >
              {busyAction === 'copy' ? (
                <Loader2Icon className='me-2 h-4 w-4 animate-spin' />
              ) : (
                <ClipboardCopyIcon className='me-2 h-4 w-4' />
              )}
              {t('Copy analysis snapshot')}
            </Button>
            <Button
              type='button'
              onClick={() => void runExport('download')}
              disabled={busyAction !== null}
            >
              {busyAction === 'download' ? (
                <Loader2Icon className='me-2 h-4 w-4 animate-spin' />
              ) : (
                <DownloadIcon className='me-2 h-4 w-4' />
              )}
              {t('Download ZIP bundle')}
            </Button>
          </div>
        </div>

        <p className='text-muted-foreground text-xs'>
          {t(
            'The clipboard action returns a plain-text bundle; the ZIP action contains separate JSON files for AI analysis.'
          )}
        </p>
      </div>
    </SettingsSection>
  )
}
