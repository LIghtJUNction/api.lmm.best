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
import { BookOpen, CircleHelp, GitBranch, type LucideIcon } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import {
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar'

const QUICK_LINKS: ReadonlyArray<{
  href: string
  icon: LucideIcon
  labelKey: string
}> = [
  {
    href: 'https://github.com/LIghtJUNction/api.lmm.best/releases',
    icon: BookOpen,
    labelKey: 'Changelog',
  },
  {
    href: 'https://github.com/LIghtJUNction/api.lmm.best',
    icon: GitBranch,
    labelKey: 'GitHub project',
  },
  {
    href: 'https://github.com/LIghtJUNction/api.lmm.best/issues',
    icon: CircleHelp,
    labelKey: 'Report an issue',
  },
]

/** Compact external destinations kept visible at the bottom of every sidebar view. */
export function SidebarQuickLinks() {
  const { t } = useTranslation()
  const { setOpenMobile } = useSidebar()

  return (
    <SidebarFooter className='border-sidebar-border border-t'>
      <SidebarGroup className='px-0 py-1'>
        <SidebarGroupLabel className='text-sidebar-foreground/60 px-2 text-[11px] font-medium tracking-wider uppercase'>
          {t('Quick links')}
        </SidebarGroupLabel>
        <SidebarMenu>
          {QUICK_LINKS.map((link) => {
            const label = t(link.labelKey)
            const Icon = link.icon

            return (
              <SidebarMenuItem key={link.href}>
                <SidebarMenuButton
                  tooltip={label}
                  render={
                    <a
                      href={link.href}
                      target='_blank'
                      rel='noopener noreferrer'
                      aria-label={label}
                      onClick={() => setOpenMobile(false)}
                    />
                  }
                >
                  <Icon className='shrink-0' aria-hidden='true' />
                  <span className='min-w-0 flex-1 truncate'>{label}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            )
          })}
        </SidebarMenu>
      </SidebarGroup>
    </SidebarFooter>
  )
}
