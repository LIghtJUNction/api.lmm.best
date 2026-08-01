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

const PROTOCOLS = [
  { name: 'OpenAI', endpoint: '/v1/chat/completions' },
  { name: 'Claude', endpoint: '/v1/messages' },
  { name: 'Gemini', endpoint: '/v1beta/models' },
  { name: 'Rerank', endpoint: '/v1/rerank' },
] as const

export function Stats() {
  const { t } = useTranslation()

  return (
    <aside
      className='border-y-2 border-[#141413] bg-[#BCD1CA] px-5 text-[#141413] sm:px-8 dark:border-[#FAF9F5]'
      aria-label={t('API Endpoints')}
    >
      <div className='mx-auto grid max-w-7xl lg:grid-cols-[15rem_1fr]'>
        <div className='flex items-center border-b border-[#141413]/35 py-6 lg:border-r lg:border-b-0 lg:pr-8'>
          <div>
            <p className='text-[0.6875rem] font-semibold tracking-[0.2em] uppercase'>
              {t('Available Models')}
            </p>
            <p className='mt-1 font-serif text-2xl leading-tight'>
              {t('API Endpoints')}
            </p>
          </div>
        </div>
        <ul
          className='grid sm:grid-cols-2 lg:grid-cols-4'
          aria-label={t('Available Models')}
        >
          {PROTOCOLS.map((protocol) => (
            <li
              key={protocol.name}
              className='border-b border-[#141413]/35 py-5 last:border-b-0 sm:odd:border-r sm:odd:pr-5 sm:even:pl-5 lg:border-r lg:border-b-0 lg:px-5 lg:last:border-r-0 lg:last:pr-0 sm:[&:nth-last-child(-n+2)]:border-b-0'
            >
              <span className='block font-serif text-lg'>{protocol.name}</span>
              <code className='mt-1 block overflow-hidden text-[0.6875rem] text-ellipsis whitespace-nowrap text-[#141413]/65'>
                {protocol.endpoint}
              </code>
            </li>
          ))}
        </ul>
      </div>
    </aside>
  )
}
