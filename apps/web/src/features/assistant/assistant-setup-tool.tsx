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
  ArrowRight,
  ExternalLink,
  KeyRound,
  Laptop,
  Terminal,
} from 'lucide-react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { CopyButton } from '@/components/copy-button'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'

import {
  getClaudeInstallCommand,
  getClaudeSessionCommand,
  type AssistantSetupPlatform,
} from './setup-guide'

const CLAUDE_INSTALL_DOCS = 'https://code.claude.com/docs/en/installation'
const CLAUDE_DESKTOP_DOCS = 'https://code.claude.com/docs/en/desktop-quickstart'
const CC_SWITCH_RELEASES = 'https://github.com/farion1231/cc-switch/releases'
const CHATGPT_DOWNLOAD = 'https://chatgpt.com/download/'
const PLATFORM_LABELS: Record<AssistantSetupPlatform, string> = {
  windows: 'Windows',
  macos: 'macOS',
  linux: 'Linux',
}
type ClientTab = 'claude-code' | 'cc-switch' | 'chatgpt'

function CodeSnippet(props: { label: string; value: string }) {
  return (
    <div className='grid gap-1.5'>
      <span className='text-muted-foreground text-xs'>{props.label}</span>
      <div className='bg-background flex items-start gap-2 rounded-lg border p-2.5'>
        <pre className='min-w-0 flex-1 overflow-x-auto font-mono text-[11px] leading-5 whitespace-pre-wrap'>
          {props.value}
        </pre>
        <CopyButton value={props.value} size='sm' />
      </div>
    </div>
  )
}

function ConnectionValue(props: { label: string; value: string }) {
  return (
    <div className='flex items-center justify-between gap-2 border-b py-2 last:border-b-0'>
      <span className='text-muted-foreground text-xs'>{props.label}</span>
      <div className='flex min-w-0 items-center gap-1.5'>
        <code className='truncate text-xs'>{props.value}</code>
        <CopyButton value={props.value} size='sm' />
      </div>
    </div>
  )
}

function OfficialLink(props: { href: string; label: string }) {
  return (
    <Button
      variant='outline'
      size='sm'
      render={<a href={props.href} target='_blank' rel='noopener noreferrer' />}
    >
      {props.label}
      <ExternalLink data-icon='inline-end' aria-hidden='true' />
    </Button>
  )
}

export function AssistantSetupTool(props: {
  rootUrl: string
  openAIBaseUrl: string
  defaultModel: string
  developerAccessGranted: boolean
  onCreateKey: () => void
}) {
  const { t } = useTranslation()
  const [platform, setPlatform] = useState<AssistantSetupPlatform>('windows')
  const [clientTab, setClientTab] = useState<ClientTab>('claude-code')
  const model = props.defaultModel || '<MODEL_ID>'
  const installCommand = getClaudeInstallCommand(platform)
  const sessionCommand = getClaudeSessionCommand(platform, props.rootUrl, model)

  return (
    <Card size='sm'>
      <CardHeader>
        <CardTitle className='flex items-center gap-2'>
          <Laptop className='size-4' aria-hidden='true' />
          {t('Client setup guide')}
        </CardTitle>
        <CardDescription>
          {t(
            'Copy the exact values for this service. API keys stay as placeholders until you create and copy one yourself.'
          )}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {!props.developerAccessGranted ? (
          <div className='bg-muted/40 mb-3 rounded-lg border p-3 text-xs leading-5'>
            {t(
              'You can install clients while L0 access is under review. API requests become available after L1 approval.'
            )}
          </div>
        ) : null}

        <Tabs
          value={clientTab}
          onValueChange={(value) => setClientTab(value as ClientTab)}
        >
          <TabsList className='grid w-full grid-cols-3'>
            <TabsTrigger value='claude-code'>Claude Code</TabsTrigger>
            <TabsTrigger value='cc-switch'>CC Switch</TabsTrigger>
            <TabsTrigger value='chatgpt'>ChatGPT</TabsTrigger>
          </TabsList>

          <TabsContent value='claude-code' className='mt-3 grid gap-3'>
            <div className='flex flex-wrap gap-2' aria-label={t('Platform')}>
              {(['windows', 'macos', 'linux'] as const).map((item) => (
                <Button
                  key={item}
                  type='button'
                  size='sm'
                  variant={platform === item ? 'default' : 'outline'}
                  onClick={() => setPlatform(item)}
                >
                  {PLATFORM_LABELS[item]}
                </Button>
              ))}
            </div>
            <CodeSnippet label={t('Install command')} value={installCommand} />
            <CodeSnippet
              label={
                platform === 'windows'
                  ? t('PowerShell session configuration')
                  : t('Shell session configuration')
              }
              value={sessionCommand}
            />
            <p className='text-muted-foreground text-xs leading-5'>
              {t(
                'These variables apply to the current terminal session. The API key is sent as a Bearer token and is never embedded by this guide.'
              )}
            </p>
            <div className='flex flex-wrap gap-2'>
              <OfficialLink
                href={CLAUDE_INSTALL_DOCS}
                label={t('Official installation guide')}
              />
              <OfficialLink
                href={CLAUDE_DESKTOP_DOCS}
                label='Claude Code Desktop'
              />
              <Button
                size='sm'
                variant='outline'
                onClick={props.onCreateKey}
                disabled={!props.developerAccessGranted}
              >
                <KeyRound data-icon='inline-start' aria-hidden='true' />
                {t('Create API key')}
              </Button>
            </div>
          </TabsContent>

          <TabsContent value='cc-switch' className='mt-3 grid gap-3'>
            <div className='flex flex-wrap gap-2'>
              <Badge variant='outline'>Windows · MSI</Badge>
              <Badge variant='outline'>macOS · DMG / Homebrew</Badge>
              <Badge variant='outline'>Linux · AppImage / deb / rpm</Badge>
            </div>
            <div className='rounded-lg border px-3'>
              <ConnectionValue label={t('Application')} value='Claude' />
              <ConnectionValue label={t('Endpoint')} value={props.rootUrl} />
              <ConnectionValue label={t('API key')} value='<YOUR_API_KEY>' />
              <ConnectionValue label={t('Primary Model')} value={model} />
            </div>
            <p className='text-muted-foreground text-xs leading-5'>
              {t(
                'Install CC Switch from its official releases, add a Claude provider with these values, then enable that provider.'
              )}
            </p>
            <div className='flex flex-wrap gap-2'>
              <OfficialLink
                href={CC_SWITCH_RELEASES}
                label={t('Open official releases')}
              />
              <Button
                size='sm'
                variant='outline'
                onClick={props.onCreateKey}
                disabled={!props.developerAccessGranted}
              >
                <KeyRound data-icon='inline-start' aria-hidden='true' />
                {t('Create API key')}
              </Button>
            </div>
          </TabsContent>

          <TabsContent value='chatgpt' className='mt-3 grid gap-3'>
            <div className='bg-muted/40 rounded-lg border p-3'>
              <div className='flex items-center gap-2 text-sm font-medium'>
                <Terminal className='size-4' aria-hidden='true' />
                {t('Official ChatGPT desktop uses OpenAI sign-in')}
              </div>
              <p className='text-muted-foreground mt-1 text-xs leading-5'>
                {t(
                  'The official ChatGPT desktop app does not accept this service Base URL and API key as a custom provider. Use CC Switch or an OpenAI-compatible client for this service.'
                )}
              </p>
            </div>
            <div className='rounded-lg border px-3'>
              <ConnectionValue
                label={t('OpenAI-compatible Base URL')}
                value={props.openAIBaseUrl}
              />
              <ConnectionValue label={t('Model ID')} value={model} />
              <ConnectionValue label={t('API key')} value='<YOUR_API_KEY>' />
            </div>
            <div className='flex flex-wrap gap-2'>
              <OfficialLink
                href={CHATGPT_DOWNLOAD}
                label={t('Download official ChatGPT')}
              />
              <Button
                size='sm'
                variant='outline'
                onClick={() => setClientTab('cc-switch')}
              >
                {t('Use CC Switch instead')}
                <ArrowRight data-icon='inline-end' aria-hidden='true' />
              </Button>
            </div>
          </TabsContent>
        </Tabs>
      </CardContent>
    </Card>
  )
}
