/*
Copyright (C) 2026 LIghtJUNction

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'

import { AuthLayout } from '@/features/auth/auth-layout'

export function OAuthPageShell(props: {
  icon: LucideIcon
  title: string
  description: string
  children: ReactNode
}) {
  const Icon = props.icon
  return (
    <AuthLayout>
      <main className='w-full space-y-5' aria-labelledby='oauth-page-title'>
        <div className='space-y-3 text-center'>
          <div className='bg-primary/10 text-primary mx-auto flex size-12 items-center justify-center rounded-xl'>
            <Icon className='size-6' aria-hidden='true' />
          </div>
          <div className='space-y-1.5'>
            <h2
              id='oauth-page-title'
              className='text-2xl font-semibold tracking-tight'
            >
              {props.title}
            </h2>
            <p className='text-muted-foreground text-sm text-pretty'>
              {props.description}
            </p>
          </div>
        </div>
        {props.children}
      </main>
    </AuthLayout>
  )
}
