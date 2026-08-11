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
import type { TFunction } from 'i18next'
import { useEffect, useRef, useState } from 'react'
import { useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'
import * as z from 'zod'

import { JsonCodeEditor } from '@/components/json-code-editor'
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form'
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Switch } from '@/components/ui/switch'

import {
  SettingsForm,
  SettingsSwitchContent,
  SettingsSwitchItem,
} from '../components/settings-form-layout'
import { SettingsPageFormActions } from '../components/settings-page-context'
import { SettingsSection } from '../components/settings-section'
import { useUpdateOption } from '../hooks/use-update-option'

const EMPTY_RULE_SET = '{\n  "version": 1,\n  "rules": []\n}'

function createAdvancedSecuritySchema(t: TFunction) {
  const advancedSecurityRulesSchema = z.string().superRefine((value, ctx) => {
    const trimmed = value.trim()
    if (!trimmed) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: t('Advanced security rules must be valid JSON.'),
      })
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(trimmed)
    } catch {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: t('Advanced security rules must be valid JSON.'),
      })
      return
    }

    let rules: unknown = null
    if (Array.isArray(parsed)) {
      rules = parsed
    } else if (parsed && typeof parsed === 'object' && 'rules' in parsed) {
      rules = parsed.rules
    }

    if (!Array.isArray(rules)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: t(
          'Rules must be a JSON array or an object with a rules array.'
        ),
      })
      return
    }

    if (rules.length > 512) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: t(
          'Advanced security rules cannot contain more than 512 rules.'
        ),
      })
      return
    }

    for (const rule of rules) {
      if (!rule || typeof rule !== 'object' || Array.isArray(rule)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: t('Each advanced security rule must be a JSON object.'),
        })
        return
      }

      const record = rule as Record<string, unknown>
      if (typeof record.id !== 'string' || !record.id.trim()) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: t(
            'Each advanced security rule must include a non-empty id.'
          ),
        })
        return
      }

      if (!Array.isArray(record.patterns) || record.patterns.length === 0) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: t(
            'Each advanced security rule must include at least one pattern.'
          ),
        })
        return
      }

      if (
        record.patterns.some(
          (pattern) => typeof pattern !== 'string' || !pattern.trim()
        )
      ) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: t('Rule patterns must be non-empty strings.'),
        })
        return
      }
    }
  })

  return z.object({
    AdvancedSecurityEnabled: z.boolean(),
    AdvancedSecurityOnPromptEnabled: z.boolean(),
    AdvancedSecurityAction: z.enum(['block', 'audit']),
    AdvancedSecurityRules: advancedSecurityRulesSchema,
  })
}

type AdvancedSecurityFormValues = z.infer<
  ReturnType<typeof createAdvancedSecuritySchema>
>

type AdvancedSecuritySectionProps = {
  defaultValues: AdvancedSecurityFormValues
}

function formatRulesForEditor(value: string) {
  const source = value.trim() || EMPTY_RULE_SET
  try {
    return JSON.stringify(JSON.parse(source), null, 2)
  } catch {
    return source
  }
}

function normalizeRules(value: string) {
  const source = value.trim() || EMPTY_RULE_SET
  try {
    return JSON.stringify(JSON.parse(source))
  } catch {
    return source
  }
}

export function AdvancedSecuritySection({
  defaultValues,
}: AdvancedSecuritySectionProps) {
  const { t } = useTranslation()
  const updateOption = useUpdateOption()
  const advancedSecuritySchema = createAdvancedSecuritySchema(t)
  const [saveState, setSaveState] = useState<'idle' | 'saved' | 'error'>('idle')
  const baselineRef = useRef({
    enabled: defaultValues.AdvancedSecurityEnabled,
    onPrompt: defaultValues.AdvancedSecurityOnPromptEnabled,
    action: defaultValues.AdvancedSecurityAction,
    rules: normalizeRules(defaultValues.AdvancedSecurityRules),
  })
  const form = useForm<AdvancedSecurityFormValues>({
    mode: 'onChange',
    resolver: zodResolver(advancedSecuritySchema),
    defaultValues: {
      ...defaultValues,
      AdvancedSecurityRules: formatRulesForEditor(
        defaultValues.AdvancedSecurityRules
      ),
    },
  })

  useEffect(() => {
    baselineRef.current = {
      enabled: defaultValues.AdvancedSecurityEnabled,
      onPrompt: defaultValues.AdvancedSecurityOnPromptEnabled,
      action: defaultValues.AdvancedSecurityAction,
      rules: normalizeRules(defaultValues.AdvancedSecurityRules),
    }
    form.reset({
      ...defaultValues,
      AdvancedSecurityRules: formatRulesForEditor(
        defaultValues.AdvancedSecurityRules
      ),
    })
    setSaveState('idle')
  }, [defaultValues, form])

  const onSubmit = async (values: AdvancedSecurityFormValues) => {
    const normalizedRules = normalizeRules(values.AdvancedSecurityRules)
    const baseline = baselineRef.current
    const updates: Array<{
      key: string
      value: string | boolean
    }> = []

    if (values.AdvancedSecurityEnabled !== baseline.enabled) {
      updates.push({
        key: 'AdvancedSecurityEnabled',
        value: values.AdvancedSecurityEnabled,
      })
    }
    if (values.AdvancedSecurityOnPromptEnabled !== baseline.onPrompt) {
      updates.push({
        key: 'AdvancedSecurityOnPromptEnabled',
        value: values.AdvancedSecurityOnPromptEnabled,
      })
    }
    if (values.AdvancedSecurityAction !== baseline.action) {
      updates.push({
        key: 'AdvancedSecurityAction',
        value: values.AdvancedSecurityAction,
      })
    }
    if (normalizedRules !== baseline.rules) {
      updates.push({ key: 'AdvancedSecurityRules', value: normalizedRules })
    }

    if (updates.length === 0) {
      toast.info(t('No changes to save'))
      return
    }

    setSaveState('idle')
    try {
      const responses = await Promise.all(
        updates.map((update) => updateOption.mutateAsync(update))
      )
      if (!responses.every((response) => response.success)) {
        setSaveState('error')
        return
      }

      baselineRef.current = {
        enabled: values.AdvancedSecurityEnabled,
        onPrompt: values.AdvancedSecurityOnPromptEnabled,
        action: values.AdvancedSecurityAction,
        rules: normalizedRules,
      }
      form.reset({
        ...values,
        AdvancedSecurityRules: formatRulesForEditor(normalizedRules),
      })
      setSaveState('saved')
    } catch {
      setSaveState('error')
    }
  }

  return (
    <SettingsSection title={t('Advanced Security')}>
      <Form {...form}>
        <SettingsForm onSubmit={form.handleSubmit(onSubmit)}>
          <SettingsPageFormActions
            onSave={form.handleSubmit(onSubmit)}
            isSaving={updateOption.isPending}
            saveLabel='Save advanced security'
          />

          <div className='border-border/60 bg-muted/20 space-y-1 rounded-lg border p-4 text-sm'>
            <p className='font-medium'>{t('Advanced security guardrail')}</p>
            <p className='text-muted-foreground'>
              {t(
                'Rules use literal, case-insensitive matching. Risk categories reference Anthropic’s public Usage Policy, but this local configuration is not an official equivalent, endorsement, or legal interpretation.'
              )}
            </p>
          </div>

          {saveState === 'saved' && !form.formState.isDirty ? (
            <p className='text-success text-sm' role='status'>
              {t('Advanced security settings saved')}
            </p>
          ) : null}
          {saveState === 'error' ? (
            <p className='text-destructive text-sm' role='alert'>
              {t('Advanced security settings could not be saved')}
            </p>
          ) : null}

          <FormField
            control={form.control}
            name='AdvancedSecurityEnabled'
            render={({ field }) => (
              <SettingsSwitchItem>
                <SettingsSwitchContent>
                  <FormLabel>{t('Enable advanced security')}</FormLabel>
                  <FormDescription>
                    {t(
                      'Apply the configured literal rules as an additional security guardrail.'
                    )}
                  </FormDescription>
                </SettingsSwitchContent>
                <FormControl>
                  <Switch
                    checked={field.value}
                    onCheckedChange={field.onChange}
                  />
                </FormControl>
              </SettingsSwitchItem>
            )}
          />

          <FormField
            control={form.control}
            name='AdvancedSecurityOnPromptEnabled'
            render={({ field }) => (
              <SettingsSwitchItem>
                <SettingsSwitchContent>
                  <FormLabel>{t('Inspect prompts before upstream')}</FormLabel>
                  <FormDescription>
                    {t(
                      'Scan user prompts before they are sent to an upstream model.'
                    )}
                  </FormDescription>
                </SettingsSwitchContent>
                <FormControl>
                  <Switch
                    checked={field.value}
                    onCheckedChange={field.onChange}
                  />
                </FormControl>
              </SettingsSwitchItem>
            )}
          />

          <FormField
            control={form.control}
            name='AdvancedSecurityAction'
            render={({ field }) => (
              <FormItem>
                <FormLabel>{t('Response action')}</FormLabel>
                <Select
                  value={field.value}
                  onValueChange={(value) => {
                    if (value === 'block' || value === 'audit') {
                      field.onChange(value)
                    }
                  }}
                >
                  <FormControl>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                  </FormControl>
                  <SelectContent alignItemWithTrigger={false}>
                    <SelectGroup>
                      <SelectItem value='block'>
                        {t('Block matching requests')}
                      </SelectItem>
                      <SelectItem value='audit'>
                        {t('Audit matches without blocking')}
                      </SelectItem>
                    </SelectGroup>
                  </SelectContent>
                </Select>
                <FormDescription>
                  {t(
                    'Choose whether a matching prompt is blocked or only recorded for review.'
                  )}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />

          <FormField
            control={form.control}
            name='AdvancedSecurityRules'
            render={({ field }) => (
              <FormItem>
                <FormLabel>{t('Advanced security rules (JSON)')}</FormLabel>
                <FormControl>
                  <JsonCodeEditor
                    value={field.value}
                    onChange={field.onChange}
                    name={field.name}
                    onBlur={field.onBlur}
                    textareaRef={field.ref}
                    placeholder={EMPTY_RULE_SET}
                    heightClassName='h-80 min-h-80 max-h-80'
                    aria-invalid={Boolean(
                      form.formState.errors.AdvancedSecurityRules
                    )}
                  />
                </FormControl>
                <FormDescription>
                  {t(
                    'Use a JSON array or an object with a rules array. Each rule needs a unique id and one or more literal patterns; matching is case-insensitive.'
                  )}
                </FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />
        </SettingsForm>
      </Form>
    </SettingsSection>
  )
}
