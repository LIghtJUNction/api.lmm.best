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
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import type { NotificationTab } from '@/components/notification-popover'
import {
  listReceivedBountyTips,
  markReceivedBountyTipsRead,
  thankBountyTip,
} from '@/features/open-source-bounties/api'
import type { BountyTipNotification } from '@/features/open-source-bounties/types'
import { useStatus } from '@/hooks/use-status'
import { getNotice } from '@/lib/api'
import { useAuthStore } from '@/stores/auth-store'
import { useNotificationStore } from '@/stores/notification-store'

function hashString(input: string): string {
  let hash = 0
  if (!input) return '0'

  for (let i = 0; i < input.length; i += 1) {
    const chr = input.charCodeAt(i)
    hash = (hash << 5) - hash + chr
    hash |= 0
  }

  return hash.toString(36)
}

/**
 * Generate a unique key for an announcement
 * Prefer backend id, fall back to a content hash so edits register
 */
function getAnnouncementKey(item: Record<string, unknown>): string {
  if (!item) return ''

  if (item.id !== undefined && item.id !== null) {
    return `id:${item.id}`
  }

  const fingerprint = JSON.stringify({
    publishDate: (item?.publishDate as string) || '',
    content: ((item?.content as string) || '').trim(),
    extra: ((item?.extra as string) || '').trim(),
    type: (item?.type as string) || '',
    title: ((item?.title as string) || '').trim(),
    link: ((item?.link as string) || '').trim(),
  })
  return `hash:${hashString(fingerprint)}`
}

/**
 * Hook to manage notifications (Notice + Announcements)
 * Provides unread counts and read status management
 */
export function useNotifications() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const userId = useAuthStore((state) => state.auth.user?.id ?? 0)
  const [popoverOpen, setPopoverOpen] = useState(false)
  const [activeTab, setActiveTab] = useState<NotificationTab>('notice')
  const [thankingTipId, setThankingTipId] = useState(0)

  // Fetch Notice from API
  const {
    data: noticeResponse,
    isLoading: noticeLoading,
    refetch: refetchNotice,
  } = useQuery({
    queryKey: ['notice'],
    queryFn: getNotice,
    staleTime: 1000 * 60 * 5, // 5 minutes
  })

  // Fetch Announcements from status
  const { status, loading: statusLoading } = useStatus()
  const announcementsEnabled = status?.announcements_enabled ?? false
  const statusAnnouncements = status?.announcements
  const announcements = useMemo<Record<string, unknown>[]>(
    () =>
      announcementsEnabled
        ? ((statusAnnouncements || []) as Record<string, unknown>[]).slice(
            0,
            20
          )
        : [],
    [announcementsEnabled, statusAnnouncements]
  )
  const { data: bountyTips = [], isLoading: bountyTipsLoading } = useQuery({
    queryKey: ['open-source-bounties', 'tip-notifications', userId],
    queryFn: listReceivedBountyTips,
    enabled: userId > 0,
    staleTime: 30_000,
    refetchInterval: 30_000,
  })

  // Notification store
  const {
    lastReadNotice,
    markNoticeRead,
    markAnnouncementsRead,
    isAnnouncementRead,
  } = useNotificationStore()

  // Extract notice content
  const noticeContent = noticeResponse?.success
    ? (noticeResponse.data || '').trim()
    : ''

  // Calculate unread counts
  const unreadCounts = useMemo(() => {
    const noticeUnread =
      noticeContent && noticeContent !== lastReadNotice ? 1 : 0

    const announcementsUnread = announcements.filter(
      (item: Record<string, unknown>) => {
        const key = getAnnouncementKey(item)
        return !isAnnouncementRead(key)
      }
    ).length
    const bountyTipsUnread = bountyTips.filter(
      (item) => item.recipient_read_at === 0
    ).length

    return {
      notice: noticeUnread,
      announcements: announcementsUnread,
      bountyTips: bountyTipsUnread,
      total: noticeUnread + announcementsUnread + bountyTipsUnread,
    }
  }, [
    noticeContent,
    lastReadNotice,
    announcements,
    isAnnouncementRead,
    bountyTips,
  ])

  const markAnnouncementsAsRead = () => {
    if (announcements.length > 0) {
      const allKeys = announcements.map((item: Record<string, unknown>) =>
        getAnnouncementKey(item)
      )
      markAnnouncementsRead(allKeys)
    }
  }

  // Handle popover open
  const markBountyTipsAsRead = () => {
    if (userId <= 0 || unreadCounts.bountyTips === 0) return
    const readAt = Math.floor(Date.now() / 1000)
    queryClient.setQueryData<BountyTipNotification[]>(
      ['open-source-bounties', 'tip-notifications', userId],
      (items = []) =>
        items.map((item) =>
          item.recipient_read_at > 0
            ? item
            : { ...item, recipient_read_at: readAt }
        )
    )
    void markReceivedBountyTipsRead().catch(() => {
      void queryClient.invalidateQueries({
        queryKey: ['open-source-bounties', 'tip-notifications', userId],
      })
    })
  }

  const handleOpenPopover = (tab?: NotificationTab) => {
    const nextTab = tab || activeTab

    // Mark currently visible content as read when opening the notification center
    if (noticeContent) {
      markNoticeRead(noticeContent)
    }
    if (nextTab === 'announcements') {
      markAnnouncementsAsRead()
    }
    if (nextTab === 'bounty-tips') {
      markBountyTipsAsRead()
    }

    setActiveTab(nextTab)
    setPopoverOpen(true)
  }

  const handlePopoverOpenChange = (open: boolean) => {
    if (open) {
      handleOpenPopover(activeTab)
      return
    }

    setPopoverOpen(false)
  }

  // Handle tab change - mark announcements as read when switching to that tab
  const handleTabChange = (tab: NotificationTab) => {
    setActiveTab(tab)

    if (tab === 'announcements') {
      markAnnouncementsAsRead()
    }
    if (tab === 'bounty-tips') {
      markBountyTipsAsRead()
    }
  }

  const handleThankTip = async (tipId: number) => {
    setThankingTipId(tipId)
    try {
      const updated = await thankBountyTip(tipId)
      queryClient.setQueryData<BountyTipNotification[]>(
        ['open-source-bounties', 'tip-notifications', userId],
        (items = []) =>
          items.map((item) => (item.id === tipId ? updated : item))
      )
      await queryClient.invalidateQueries({
        queryKey: ['open-source-bounties'],
      })
      toast.success(t('Thanks sent'))
    } catch {
      toast.error(t('Unable to send thanks'))
    } finally {
      setThankingTipId(0)
    }
  }

  return {
    // Data
    notice: noticeContent,
    announcements,
    bountyTips,
    loading: noticeLoading || statusLoading || bountyTipsLoading,

    // Unread counts
    unreadCount: unreadCounts.total,
    unreadNoticeCount: unreadCounts.notice,
    unreadAnnouncementsCount: unreadCounts.announcements,

    // Popover state
    popoverOpen,
    setPopoverOpen: handlePopoverOpenChange,
    activeTab,
    setActiveTab: handleTabChange,
    thankingTipId,

    // Actions
    openPopover: handleOpenPopover,
    closePopover: () => setPopoverOpen(false),
    refetchNotice,
    thankTip: handleThankTip,
  }
}
