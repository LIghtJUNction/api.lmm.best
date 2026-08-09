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
import { ThemeSwitch } from '@/components/theme-switch'

import { AuthArtPanel } from './components/auth-art-panel'

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
    <div className='relative min-h-svh max-w-none lg:grid lg:grid-cols-[minmax(31rem,0.92fr)_minmax(31rem,1.08fr)]'>
      <header className='absolute inset-x-0 top-0 z-20 flex min-h-20 items-center justify-between px-4 sm:min-h-24 sm:px-8'>
        <Link
          to='/'
          className='flex items-center gap-2 transition-opacity hover:opacity-80'
        >
          <LmmBrandMark className='size-8' title='LMM Forge' />
          <h1 className='text-xl font-medium'>LMM Forge</h1>
        </Link>
        <ThemeSwitch />
      </header>
      <div className='grid min-h-svh grid-rows-[1fr_auto] lg:col-start-1'>
        <div className='container flex items-start pt-20 sm:pt-24'>
          <div className='mx-auto flex w-full flex-col justify-center space-y-2 px-4 py-8 sm:w-[480px] sm:px-8 sm:py-12'>
            {children}
          </div>
        </div>
        <AccessRestrictionNotice />
      </div>
      <div className='hidden lg:sticky lg:top-0 lg:col-start-2 lg:row-start-1 lg:block lg:h-svh lg:min-h-[42rem] lg:p-3 lg:pl-0'>
        <AuthArtPanel />
      </div>
    </div>
  )
}
