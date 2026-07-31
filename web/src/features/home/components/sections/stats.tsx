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

const PROTOCOLS = ['OpenAI', 'Claude', 'Gemini', 'Rerank'] as const

export function Stats() {
  const { t } = useTranslation()

  return (
    <aside
      className='bg-[#141413] px-5 py-8 text-[#FAF9F5] sm:px-8'
      aria-label={t('API Endpoints')}
    >
      <div className='mx-auto flex max-w-6xl flex-col gap-5 md:flex-row md:items-center md:justify-between'>
        <p className='max-w-md font-serif text-2xl leading-tight'>
          {t('API Endpoints')}
        </p>
        <ul
          className='flex flex-wrap gap-x-6 gap-y-2'
          aria-label={t('Available Models')}
        >
          {PROTOCOLS.map((protocol) => (
            <li key={protocol} className='text-sm text-[#FAF9F5]/75'>
              {protocol}
            </li>
          ))}
        </ul>
      </div>
    </aside>
  )
}
