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
import { useTranslation } from 'react-i18next'

import { cn } from '@/lib/utils'

type AccessRestrictionNoticeProps = {
  className?: string
}

export function AccessRestrictionNotice(props: AccessRestrictionNoticeProps) {
  const { t } = useTranslation()

  return (
    <aside
      role='note'
      className={cn(
        'border-border bg-muted/40 text-muted-foreground border-t px-4 py-2 text-center text-[11px] leading-4 font-medium',
        props.className
      )}
    >
      {t('Regional access statement')}
    </aside>
  )
}
