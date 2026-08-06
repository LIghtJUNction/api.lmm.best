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
import { useEffect } from 'react'

import { AccessRestrictionNotice } from '@/components/access-restriction-notice'
import { LmmBrandMark } from '@/components/lmm-brand-mark'

type AuthLayoutProps = {
  children: React.ReactNode
}

export function AuthLayout({ children }: AuthLayoutProps) {
  useEffect(() => {
    const previousTitle = document.title
    document.title = 'LMM Forge'
    return () => {
      document.title = previousTitle
    }
  }, [])

  return (
    <div className='relative grid min-h-svh max-w-none grid-rows-[1fr_auto]'>
      <Link
        to='/'
        className='absolute top-4 left-4 z-10 flex items-center gap-2 transition-opacity hover:opacity-80 sm:top-8 sm:left-8'
      >
        <LmmBrandMark className='size-8' title='LMM Forge' />
        <h1 className='text-xl font-medium'>LMM Forge</h1>
      </Link>
      <div className='container flex items-center pt-16 sm:pt-0'>
        <div className='mx-auto flex w-full flex-col justify-center space-y-2 px-4 py-8 sm:w-[480px] sm:p-8'>
          {children}
        </div>
      </div>
      <AccessRestrictionNotice />
    </div>
  )
}
