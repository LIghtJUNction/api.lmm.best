/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
*/
// Temporary branch-only harness. It renders the real Todos component with
// an in-memory transport; there is no production backend or login involved.
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const app = new URL('../apps/web/', import.meta.url)
const write = (name, content) => writeFileSync(new URL(name, app), content)

write('.todo-review.config.ts', `
import path from 'node:path'
import { defineConfig } from '@rsbuild/core'
import { pluginReact } from '@rsbuild/plugin-react'
import { pluginTailwindcss } from '@rsbuild/plugin-tailwindcss'
export default defineConfig({
  plugins: [pluginReact(), pluginTailwindcss({ optimize: false })],
  source: { entry: { index: './.todo-review-entry.tsx' }, define: { __LMM_PERSONA_DEBUG__: 'false' } },
  resolve: { alias: { '@': path.resolve('./src') } },
  html: { template: './index.html' },
  dev: { lazyCompilation: false },
  server: { host: '127.0.0.1', port: 4174, strictPort: true },
})
`)

write('.todo-review-entry.tsx', `
import { createElement, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { Outlet, RouterProvider, createMemoryHistory, createRootRoute, createRoute, createRouter } from '@tanstack/react-router'
import { I18nextProvider } from 'react-i18next'
import '@/styles/index.css'
import i18n from '@/i18n/config'
import { api } from '@/lib/api'
import { useAuthStore } from '@/stores/auth-store'
import { Todos } from '@/features/todos'
import type { TodoItem } from '@/features/todos/api'

const isAdmin = new URL(location.href).searchParams.get('viewer') !== 'user'
useAuthStore.getState().auth.setUser({ id: 10, username: 'review-fixture', role: isAdmin ? 10 : 1 })
const read = new Set<number>()
const categories = isAdmin
  ? ['open_source_bounty_review', 'human_support', 'account_action', 'developer_access', 'security_incident', 'security_review', 'open_source_bounty'] as const
  : ['open_source_bounty'] as const
const titles = {
  open_source_bounty_review: 'open_source_bounty.challenge_submitted',
  human_support: 'assistant.human_support',
  account_action: 'account_action.pending',
  developer_access: 'developer_access.pending',
  security_incident: 'security_incident.pending',
  security_review: 'assistant.security_review',
  open_source_bounty: 'open_source_bounty.comment',
}
const items: TodoItem[] = Array.from({ length: 61 }, (_, index) => {
  const category = categories[index % categories.length]
  return {
    id: category + ':' + (index + 1), source_id: index + 1, category, type: 'fixture',
    title: titles[category], read: false,
    summary: '验证待办 #' + (index + 1) + ' · 请检查请求的处理进度。这里包含较长的说明，用于确认手机上文字可以自然换行，不会挤掉操作入口。',
    created_at: Math.floor(Date.now() / 1000) - index * 1800,
    updated_at: Math.floor(Date.now() / 1000) - index * 1800,
    details: { user_id: index + 20, username: index === 0 ? 'a-very-long-fixture-username-for-mobile-layout' : 'fixture-' + (index + 1), email: 'layout-review-' + (index + 1) + '@example.invalid', status: 'pending', project_id: index + 1 },
  }
})
const envelope = (data: unknown) => ({ data: { success: true, data } })
api.get = (async (url: string) => {
  const parsed = new URL(url, 'http://127.0.0.1:4174')
  if (parsed.pathname !== '/api/todos') throw new Error('Unexpected fixture GET: ' + parsed.pathname)
  await new Promise((resolve) => setTimeout(resolve, 100))
  const category = parsed.searchParams.get('category') ?? 'all'
  const currentPage = Number(parsed.searchParams.get('p') ?? 1)
  const filtered = items.filter((item) => category === 'all' || item.category === category)
  const summaries = categories.map((key) => ({ key, total: items.filter((item) => item.category === key).length, unread: items.filter((item) => item.category === key && !read.has(item.source_id)).length }))
  return envelope({
    items: filtered.slice((currentPage - 1) * 50, currentPage * 50).map((item) => ({ ...item, read: read.has(item.source_id) })),
    page: currentPage, page_size: 50, total: filtered.length, category,
    unread_count: filtered.filter((item) => !read.has(item.source_id)).length,
    total_unread_count: items.filter((item) => !read.has(item.source_id)).length,
    unread_by_category: Object.fromEntries(summaries.map((item) => [item.key, item.unread])), categories: summaries,
  })
}) as typeof api.get
api.post = (async (url: string, body: { all: boolean; ids: number[] }) => {
  if (url !== '/api/todos/read') throw new Error('Unexpected fixture POST: ' + url)
  if (body.all) items.forEach((item) => read.add(item.source_id))
  else body.ids.forEach((id) => read.add(id))
  return envelope({ marked: body.all ? items.length : body.ids.length })
}) as typeof api.post
const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
const rootRoute = createRootRoute({ component: () => (
  <QueryClientProvider client={client}><I18nextProvider i18n={i18n}>
    <div style={{ height: '100dvh', display: 'flex', flexDirection: 'column' }}>
      <Suspense fallback='Loading'><Outlet /></Suspense>
    </div>
  </I18nextProvider></QueryClientProvider>
) })
const authRoute = createRoute({ getParentRoute: () => rootRoute, id: '_authenticated', component: Outlet })
const todosRoute = createRoute({ getParentRoute: () => authRoute, path: '/todos/', component: Todos })
const router = createRouter({ routeTree: rootRoute.addChildren([authRoute.addChildren([todosRoute])]), history: createMemoryHistory({ initialEntries: ['/todos/'] }) })
;(window as any).__todoReviewI18n = i18n
void i18n.changeLanguage('zhCN').then(() => createRoot(document.getElementById('root')!).render(createElement(RouterProvider, { router })))
`)

write('.todo-review-browser.cjs', `
const assert = require('node:assert/strict')
const path = require('node:path')
const fs = require('node:fs')
const { createRequire } = require('node:module')
const requireBrowser = createRequire(path.join(process.env.PLAYWRIGHT_HOME, 'package.json'))
const { chromium } = requireBrowser('playwright')
const output = process.env.TODO_VERIFY_OUTPUT
const base = 'http://127.0.0.1:4174'
;(async () => {
  const browser = await chromium.launch({ headless: true })
  const evidence = []
  try {
    for (const scenario of [
      { name: 'desktop-light', width: 1440, height: 1000, dark: false, admin: true },
      { name: 'desktop-dark', width: 1440, height: 1000, dark: true, admin: true },
      { name: 'mobile-light', width: 390, height: 844, dark: false, admin: true },
      { name: 'mobile-dark', width: 390, height: 844, dark: true, admin: true },
      { name: 'mobile-user', width: 390, height: 844, dark: false, admin: false },
    ]) {
      const context = await browser.newContext({ viewport: { width: scenario.width, height: scenario.height }, serviceWorkers: 'block' })
      const page = await context.newPage()
      const errors = []
      const blocked = []
      page.on('pageerror', (error) => errors.push(String(error)))
      await context.addInitScript(() => localStorage.setItem('i18nextLng', 'zhCN'))
      await context.route('**/*', async (route) => {
        const url = new URL(route.request().url())
        if (url.origin !== base || url.pathname.startsWith('/api/')) {
          blocked.push(url.pathname)
          await route.abort('blockedbyclient')
        } else await route.continue()
      })
      await page.goto(base + (scenario.admin ? '/' : '/?viewer=user'))
      await page.locator('section ul li').first().waitFor({ timeout: 90000 })
      await page.evaluate(async (dark) => { document.documentElement.classList.toggle('dark', dark); await document.fonts.ready }, scenario.dark)
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, scenario.name + ': horizontal overflow')
      assert.equal(await page.locator('details').count(), scenario.admin ? 3 : 0)
      await page.screenshot({ path: path.join(output, scenario.name + '.png') })
      if (scenario.name === 'desktop-light') {
        await page.evaluate(() => window.__todoReviewI18n.changeLanguage('en'))
        await page.getByRole('button', { name: 'Next page', exact: true }).click()
        await page.getByText('验证待办 #51 ·', { exact: false }).waitFor()
        await page.getByRole('button', { name: 'Previous page', exact: true }).click()
        await page.getByText('验证待办 #1 ·', { exact: false }).waitFor()
        await page.getByRole('button', { name: 'Mark all as read', exact: true }).click()
        await page.getByRole('button', { name: 'Mark all as read', exact: true }).waitFor({ state: 'detached' })
      }
      assert.deepEqual(errors, [], scenario.name + ': browser errors')
      assert.deepEqual(blocked, [], scenario.name + ': unexpected network requests')
      evidence.push({ ...scenario, errors, blocked, passed: true })
      await context.close()
    }
  } finally {
    fs.writeFileSync(path.join(output, 'browser-report.json'), JSON.stringify(evidence, null, 2))
    await browser.close()
  }
})().catch((error) => { console.error(error); process.exitCode = 1 })
`)
console.log('Generated local-only Todo preview in', fileURLToPath(app))
