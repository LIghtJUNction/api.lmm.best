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
import { zodResolver } from '@hookform/resolvers/zod'
import { useEffect } from 'react'
import { useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import * as z from 'zod'

import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'

import {
  SettingsForm,
  SettingsSwitchContent,
  SettingsSwitchItem,
} from '../components/settings-form-layout'
import { SettingsPageFormActions } from '../components/settings-page-context'
import { SettingsSection } from '../components/settings-section'
import { useUpdateOption } from '../hooks/use-update-option'
import { safeNumberFieldProps } from '../utils/numeric-field'

const assistantSettingsSchema = z.object({
  AssistantEnabled: z.boolean(),
  AssistantModel: z.string().trim().min(1).max(128),
  AssistantWeeklyCreditUSD: z.number().min(0).max(1000),
  AssistantAgentLoopEnabled: z.boolean(),
  AssistantMaxSteps: z.number().int().min(1).max(12),
  AssistantTimeoutSeconds: z.number().int().min(5).max(120),
  AssistantCacheEnabled: z.boolean(),
  AssistantCacheTTLMinutes: z.number().int().min(0).max(10080),
})

type AssistantSettingsFormValues = z.infer<typeof assistantSettingsSchema>

export function AssistantSettingsSection(props: {
  defaultValues: AssistantSettingsFormValues
}) {
  const { t } = useTranslation()
  const updateOption = useUpdateOption()
  const form = useForm<AssistantSettingsFormValues>({
    resolver: zodResolver(assistantSettingsSchema),
    defaultValues: props.defaultValues,
  })

  useEffect(() => {
    form.reset(props.defaultValues)
  }, [form, props.defaultValues])

  const onSubmit = async (values: AssistantSettingsFormValues) => {
    const updates = Object.entries(values).filter(
      ([key, value]) =>
        value !== props.defaultValues[key as keyof AssistantSettingsFormValues]
    )

    for (const [key, value] of updates) {
      await updateOption.mutateAsync({ key, value })
    }
  }

  const enabled = form.watch('AssistantEnabled')
  const agentLoopEnabled = form.watch('AssistantAgentLoopEnabled')
  const cacheEnabled = form.watch('AssistantCacheEnabled')

  return (
    <SettingsSection title={t('AI assistant settings')}>
      <Form {...form}>
        <SettingsForm onSubmit={form.handleSubmit(onSubmit)}>
          <SettingsPageFormActions
            onSave={form.handleSubmit(onSubmit)}
            isSaving={updateOption.isPending}
            saveLabel='Save assistant settings'
          />

          <FormField
            control={form.control}
            name='AssistantEnabled'
            render={({ field }) => (
              <SettingsSwitchItem>
                <SettingsSwitchContent>
                  <FormLabel>{t('Enable AI assistant')}</FormLabel>
                  <FormDescription>
                    {t(
                      'Show the assistant launcher and allow assistant conversations.'
                    )}
                  </FormDescription>
                </SettingsSwitchContent>
                <FormControl>
                  <Switch
                    checked={field.value}
                    onCheckedChange={field.onChange}
                  />
                </FormControl>
                <FormMessage />
              </SettingsSwitchItem>
            )}
          />

          <div className='grid gap-6 sm:grid-cols-2'>
            <FormField
              control={form.control}
              name='AssistantModel'
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{t('Default assistant model')}</FormLabel>
                  <FormControl>
                    <Input
                      {...field}
                      disabled={!enabled}
                      placeholder='deepseek-v4-flash'
                      autoComplete='off'
                    />
                  </FormControl>
                  <FormDescription>
                    {t('Model ID used for assistant conversations.')}
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name='AssistantWeeklyCreditUSD'
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{t('Weekly included credit (USD)')}</FormLabel>
                  <FormControl>
                    <Input
                      type='number'
                      min={0}
                      max={1000}
                      step={0.01}
                      {...safeNumberFieldProps(field)}
                      disabled={!enabled}
                    />
                  </FormControl>
                  <FormDescription>
                    {t(
                      'System-funded assistant credit available to each user every week before account balance is charged.'
                    )}
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />
          </div>

          <div className='border-border/60 bg-muted/20 space-y-4 rounded-lg border p-4'>
            <div>
              <h3 className='text-sm font-medium'>{t('Agent runtime')}</h3>
              <p className='text-muted-foreground mt-1 text-sm'>
                {t(
                  'Configure the assistant tool loop and its safety limits. Tool actions that change an account still require explicit confirmation.'
                )}
              </p>
            </div>

            <FormField
              control={form.control}
              name='AssistantAgentLoopEnabled'
              render={({ field }) => (
                <SettingsSwitchItem>
                  <SettingsSwitchContent>
                    <FormLabel>{t('Enable agent tool loop')}</FormLabel>
                    <FormDescription>
                      {t(
                        'Allow the assistant to call safe information and calculation tools before producing its final answer.'
                      )}
                    </FormDescription>
                  </SettingsSwitchContent>
                  <FormControl>
                    <Switch
                      checked={field.value}
                      onCheckedChange={field.onChange}
                      disabled={!enabled}
                    />
                  </FormControl>
                  <FormMessage />
                </SettingsSwitchItem>
              )}
            />

            <div className='grid gap-6 sm:grid-cols-2'>
              <FormField
                control={form.control}
                name='AssistantMaxSteps'
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>{t('Maximum agent steps')}</FormLabel>
                    <FormControl>
                      <Input
                        type='number'
                        min={1}
                        max={12}
                        step={1}
                        {...safeNumberFieldProps(field)}
                        disabled={!enabled || !agentLoopEnabled}
                      />
                    </FormControl>
                    <FormDescription>
                      {t(
                        'Maximum number of model/tool turns in one assistant request (1–12).'
                      )}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name='AssistantTimeoutSeconds'
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>{t('Agent timeout (seconds)')}</FormLabel>
                    <FormControl>
                      <Input
                        type='number'
                        min={5}
                        max={120}
                        step={1}
                        {...safeNumberFieldProps(field)}
                        disabled={!enabled || !agentLoopEnabled}
                      />
                    </FormControl>
                    <FormDescription>
                      {t(
                        'Hard limit for the complete agent loop (5–120 seconds).'
                      )}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>

            <FormField
              control={form.control}
              name='AssistantCacheEnabled'
              render={({ field }) => (
                <SettingsSwitchItem>
                  <SettingsSwitchContent>
                    <FormLabel>
                      {t('Cache identical first questions')}
                    </FormLabel>
                    <FormDescription>
                      {t(
                        'Return the same successful answer for an identical first question during the cache window without calling an upstream model.'
                      )}
                    </FormDescription>
                  </SettingsSwitchContent>
                  <FormControl>
                    <Switch
                      checked={field.value}
                      onCheckedChange={field.onChange}
                      disabled={!enabled}
                    />
                  </FormControl>
                  <FormMessage />
                </SettingsSwitchItem>
              )}
            />

            <FormField
              control={form.control}
              name='AssistantCacheTTLMinutes'
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{t('Cache window (minutes)')}</FormLabel>
                  <FormControl>
                    <Input
                      type='number'
                      min={0}
                      max={10080}
                      step={1}
                      {...safeNumberFieldProps(field)}
                      disabled={!enabled || !cacheEnabled}
                    />
                  </FormControl>
                  <FormDescription>
                    {t('Set to 0 to disable caching; the maximum is 7 days.')}
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />
          </div>
        </SettingsForm>
      </Form>
    </SettingsSection>
  )
}
