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
import { Loader2 } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { CardFooter } from '@/components/ui/card'

export function OAuthDecisionActions(props: {
  approveLabel: string
  denyLabel: string
  pending: boolean
  pendingDecision?: boolean
  disabled?: boolean
  approveType?: 'button' | 'submit'
  onApprove?: () => void
  onDeny: () => void
}) {
  const disabled = props.disabled || props.pending
  return (
    <CardFooter className='grid grid-cols-1 gap-2 sm:grid-cols-2'>
      <Button
        type='button'
        variant='outline'
        size='lg'
        disabled={disabled}
        onClick={props.onDeny}
      >
        {props.pending && props.pendingDecision === false && (
          <Loader2 className='animate-spin' aria-hidden='true' />
        )}
        {props.denyLabel}
      </Button>
      <Button
        type={props.approveType ?? 'button'}
        size='lg'
        disabled={disabled}
        onClick={props.onApprove}
      >
        {props.pending && props.pendingDecision === true && (
          <Loader2 className='animate-spin' aria-hidden='true' />
        )}
        {props.approveLabel}
      </Button>
    </CardFooter>
  )
}
