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
import { useQuery } from '@tanstack/react-query'
import { Calculator } from 'lucide-react'
import { type ReactNode, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { Badge } from '@/components/ui/badge'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { NativeSelect, NativeSelectOption } from '@/components/ui/native-select'
import { getPricing } from '@/features/pricing/api'

import { calculateAssistantTextCost } from './cost-calculator'

function parseTokenCount(value: string): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : Number.NaN
}

export function AssistantCostTool(props: {
  defaultModel: string
  developerAccessGranted: boolean
}) {
  const { t, i18n } = useTranslation()
  const [modelName, setModelName] = useState('')
  const [group, setGroup] = useState('')
  const [inputTokens, setInputTokens] = useState('100000')
  const [outputTokens, setOutputTokens] = useState('10000')
  const pricingQuery = useQuery({
    queryKey: ['pricing'],
    queryFn: getPricing,
    enabled: props.developerAccessGranted,
    staleTime: 5 * 60 * 1000,
    retry: false,
  })

  const models = useMemo(
    () =>
      (pricingQuery.data?.data ?? [])
        .filter(
          (model) =>
            model.quota_type === 0 && model.billing_mode !== 'tiered_expr'
        )
        .sort((left, right) => left.model_name.localeCompare(right.model_name)),
    [pricingQuery.data?.data]
  )
  const selectedModel =
    models.find((model) => model.model_name === modelName) ??
    models.find((model) => model.model_name === props.defaultModel) ??
    models[0]
  const groups = (selectedModel?.enable_groups ?? []).filter(
    (name) => pricingQuery.data?.usable_group[name]
  )
  const selectedGroup = groups.includes(group) ? group : (groups[0] ?? '')
  const groupRatio = selectedGroup
    ? (pricingQuery.data?.group_ratio[selectedGroup] ?? 1)
    : 1
  const estimate = selectedModel
    ? calculateAssistantTextCost(
        selectedModel,
        groupRatio,
        parseTokenCount(inputTokens),
        parseTokenCount(outputTokens)
      )
    : null
  const currency = useMemo(
    () =>
      new Intl.NumberFormat(i18n.language, {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: 4,
        maximumFractionDigits: 6,
      }),
    [i18n.language]
  )

  if (!props.developerAccessGranted) {
    return (
      <Card size='sm' className='border-dashed'>
        <CardHeader>
          <CardTitle>{t('Live cost calculation requires L1')}</CardTitle>
          <CardDescription>
            {t(
              'Only L0 is restricted. After L1 approval, this calculator uses the live model and group prices from your account.'
            )}
          </CardDescription>
        </CardHeader>
      </Card>
    )
  }

  let calculatorContent: ReactNode
  if (pricingQuery.isLoading) {
    calculatorContent = (
      <p className='text-muted-foreground text-sm'>{t('Loading...')}</p>
    )
  } else if (pricingQuery.isError || !selectedModel) {
    calculatorContent = (
      <p className='text-destructive text-sm'>
        {t('Unable to load live pricing')}
      </p>
    )
  } else {
    calculatorContent = (
      <>
        <div className='grid gap-1.5'>
          <Label htmlFor='assistant-cost-model'>{t('Model')}</Label>
          <NativeSelect
            className='w-full'
            id='assistant-cost-model'
            value={selectedModel.model_name}
            onChange={(event) => {
              setModelName(event.target.value)
              setGroup('')
            }}
          >
            {models.map((model) => (
              <NativeSelectOption
                key={model.model_name}
                value={model.model_name}
              >
                {model.model_name}
              </NativeSelectOption>
            ))}
          </NativeSelect>
        </div>
        <div className='grid gap-1.5'>
          <Label htmlFor='assistant-cost-group'>{t('Group')}</Label>
          <NativeSelect
            className='w-full'
            id='assistant-cost-group'
            value={selectedGroup}
            disabled={groups.length === 0}
            onChange={(event) => setGroup(event.target.value)}
          >
            {groups.map((name) => (
              <NativeSelectOption key={name} value={name}>
                {pricingQuery.data?.usable_group[name]?.desc || name}
              </NativeSelectOption>
            ))}
          </NativeSelect>
        </div>
        <div className='grid grid-cols-2 gap-3'>
          <div className='grid gap-1.5'>
            <Label htmlFor='assistant-input-tokens'>{t('Input tokens')}</Label>
            <Input
              id='assistant-input-tokens'
              type='number'
              min={0}
              step={1000}
              inputMode='numeric'
              value={inputTokens}
              onChange={(event) => setInputTokens(event.target.value)}
            />
          </div>
          <div className='grid gap-1.5'>
            <Label htmlFor='assistant-output-tokens'>
              {t('Output tokens')}
            </Label>
            <Input
              id='assistant-output-tokens'
              type='number'
              min={0}
              step={1000}
              inputMode='numeric'
              value={outputTokens}
              onChange={(event) => setOutputTokens(event.target.value)}
            />
          </div>
        </div>
        {estimate ? (
          <div className='bg-muted/50 grid gap-2 rounded-lg border p-3'>
            <div className='flex items-center justify-between gap-3'>
              <span className='text-muted-foreground text-xs'>
                {t('Estimated text cost')}
              </span>
              <strong className='text-base'>
                {currency.format(estimate.totalUSD)}
              </strong>
            </div>
            <div className='flex flex-wrap gap-2'>
              <Badge variant='outline'>
                {t('Input {{amount}} / 1M', {
                  amount: currency.format(estimate.inputRatePerMillionUSD),
                })}
              </Badge>
              <Badge variant='outline'>
                {t('Output {{amount}} / 1M', {
                  amount: currency.format(estimate.outputRatePerMillionUSD),
                })}
              </Badge>
            </div>
          </div>
        ) : (
          <p className='text-destructive text-sm'>
            {t('Enter valid token counts to calculate the estimate.')}
          </p>
        )}
      </>
    )
  }

  return (
    <Card size='sm'>
      <CardHeader>
        <CardTitle className='flex items-center gap-2'>
          <Calculator className='size-4' aria-hidden='true' />
          {t('Live token cost calculator')}
        </CardTitle>
        <CardDescription>
          {t(
            'Uses current server pricing. Images, audio, tools, and cache may add separate charges.'
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className='grid gap-3'>{calculatorContent}</CardContent>
    </Card>
  )
}
