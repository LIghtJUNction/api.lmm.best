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
import { PublicLayout } from '@/components/layout'

type ForgePublicShellProps = {
  children: React.ReactNode
}

function ForgeMark() {
  return (
    <span
      className='relative block size-7 -rotate-3 border-[3px] border-[#141413] before:absolute before:top-[6px] before:left-[3px] before:h-[3px] before:w-4 before:rotate-12 before:bg-[#141413] after:absolute after:top-[7px] after:left-[11px] after:h-3 after:w-[3px] after:-rotate-6 after:bg-[#141413]'
      aria-hidden='true'
    />
  )
}

export function ForgePublicShell(props: ForgePublicShellProps) {
  return (
    <PublicLayout
      showMainContainer={false}
      siteName='LMM Forge'
      logo={<ForgeMark />}
      navLinks={[
        { title: 'Challenges', href: '/challenges' },
        { title: 'How it works', href: '/#workflow' },
      ]}
      showNotifications={false}
      headerProps={{
        useDynamicNavLinks: false,
        className:
          '[&>div>nav]:bg-[#FAF9F5]/82 [&>div>nav]:backdrop-blur-md [&>div>nav]:border-[#141413]/20',
      }}
    >
      <div className='min-h-svh bg-[#FAF9F5] text-[#141413]'>
        {props.children}
      </div>
    </PublicLayout>
  )
}
