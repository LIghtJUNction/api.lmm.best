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
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdir, readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Kept outside package dependencies so this evidence script can use a globally
// installed Playwright in constrained review environments.
const { chromium } = (await import('/usr/lib/node_modules/playwright/index.js'))
  .default

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const outputDirectory = path.resolve(
  scriptDirectory,
  '../test-results/forge-closeout-review'
)
const baseUrl = process.env.BRAND_REVIEW_URL ?? 'http://127.0.0.1:4174'
const themeCookieName = 'vite-ui-theme'
const accessPolicy =
  'Service access notice: This notice refers only to ISO 3166-1 alpha-2 CN (Mainland China). It does not state service availability for any other location.'

async function fileSha256(filePath) {
  return createHash('sha256')
    .update(await readFile(filePath))
    .digest('hex')
}

const statusPayload = {
  success: true,
  data: {
    system_name: 'LMM Forge',
    logo: '/logo.png',
    version: 'review-fixture',
    footer_html: '',
    demo_site_enabled: true,
    display_token_stat_enabled: false,
    display_in_currency: false,
    backend_capabilities: {
      bounty_public_read: true,
      bounty_challenge_cancel: false,
      bounty_notifications: false,
      self_oauth_unbind: false,
      responses_websocket: false,
    },
  },
}

const challenge = {
  id: 1,
  owner_user_id: 7,
  owner_username: 'maintainer',
  repository_url: 'https://github.com/example/forge-project',
  title: 'Improve contributor onboarding',
  description: 'Create a focused onboarding path for first-time contributors.',
  rules: 'Open an issue before implementation. Link the final pull request.',
  reward_quota: 500_000,
  net_reward_quota: 475_000,
  reward_slots: 2,
  escrow_quota: 1_000_000,
  platform_fee_rate_bps: 500,
  platform_fee_quota: 50_000,
  status: 'published',
  created_at: 1_787_900_000,
  updated_at: 1_787_900_000,
  published_at: 1_787_900_000,
  closed_at: 0,
  active_challenge_count: 1,
  approved_challenge_count: 0,
  owner_rating_average: 4.8,
  owner_rating_count: 12,
  owner_thank_heart_count: 9,
}

const challengeDetail = {
  project: challenge,
  challenges: [
    {
      id: 11,
      project_id: challenge.id,
      participant_user_id: 19,
      participant_username: 'contributor',
      github_handle: 'contributor',
      status: 'submitted',
      issue_url: 'https://github.com/example/forge-project/issues/42',
      pull_request_url: 'https://github.com/example/forge-project/pull/51',
      submission_note: 'Ready for review.',
      review_note: '',
      reward_quota: 475_000,
      tip_quota: 0,
      owner_rating_score: 0,
      owner_rating_comment: '',
      owner_rated_at: 0,
      contributor_rating_score: 0,
      contributor_rating_comment: '',
      contributor_rated_at: 0,
      accepted_at: 1_787_910_000,
      submitted_at: 1_787_920_000,
      reviewed_at: 0,
      paid_at: 0,
    },
  ],
  ledger: [
    {
      id: 21,
      project_id: challenge.id,
      challenge_id: 11,
      user_id: 19,
      counterparty_user_id: 7,
      kind: 'challenge_submitted',
      quota: 0,
      note: 'Pull request submitted for review.',
      created_at: 1_787_920_000,
    },
  ],
}

const contributor = {
  id: 19,
  username: 'contributor',
  display_name: 'Contributor',
  role: 1,
  quota: 0,
  permissions: { console_activated_at: 0 },
}

const authBundle = {
  access_token: 'forge-review-access-token',
  token_type: 'Bearer',
  access_expires_at: 2_000_000_000,
  user: contributor,
  session: {
    sid: 'forge-review-session',
    current: true,
    login_method: 'password',
    ip: '127.0.0.1',
    user_agent: 'Playwright',
    created_at: 1_787_900_000,
    last_active_at: 1_787_900_000,
    expires_at: 2_000_000_000,
  },
}

function setupPayload(initialized) {
  return {
    success: true,
    data: {
      status: initialized,
      root_init: initialized,
      SelfUseModeEnabled: false,
      DemoSiteEnabled: false,
    },
  }
}

async function installApiFixtures(page, initialized, authenticated) {
  await page.route('**/api/**', async (route) => {
    const pathname = new URL(route.request().url()).pathname
    let json = { success: true, data: {} }
    let status = 200

    if (pathname === '/api/status') json = statusPayload
    if (pathname === '/api/notice') json = { success: true, data: '' }
    if (pathname === '/api/home_page_content') {
      json = { success: true, data: '' }
    }
    if (pathname === '/api/pricing') {
      json = {
        success: true,
        data: [
          {
            id: 1,
            model_name: 'forge-review-model',
            quota_type: 0,
            model_ratio: 1,
            completion_ratio: 1,
            enable_groups: ['default'],
            tags: 'review',
          },
        ],
        vendors: [],
        group_ratio: { default: 1 },
        usable_group: { default: { desc: 'Default', ratio: 1 } },
        supported_endpoint: {},
        auto_groups: [],
      }
    }
    if (pathname === '/api/setup') json = setupPayload(initialized)
    if (pathname === '/api/user/auth/refresh') {
      if (authenticated) {
        json = { success: true, data: authBundle }
      } else {
        json = { success: false, message: 'anonymous' }
        status = 401
      }
    }
    if (pathname === '/api/user/self') {
      json = { success: true, data: contributor }
    }
    if (pathname === '/api/open-source-bounties/tips/received') {
      json = { success: true, data: [] }
    }
    if (pathname === '/api/open-source-bounties') {
      json = {
        success: true,
        data: { items: [challenge], total: 1, page: 1, page_size: 50 },
      }
    }
    if (pathname === '/api/open-source-bounties/projects/1') {
      json = { success: true, data: challengeDetail }
    }

    await route.fulfill({ status, contentType: 'application/json', json })
  })
}

function assertNoDefaultLogoRequest(requestUrls) {
  assert.equal(
    requestUrls.some(
      (requestUrl) => new URL(requestUrl).pathname === '/logo.png'
    ),
    false,
    `default logo unexpectedly requested: ${requestUrls.join(', ')}`
  )
}

async function verifyPage({
  name,
  pathname,
  viewport,
  colorScheme,
  initialized,
  authenticated = false,
}) {
  const harPath = path.join(outputDirectory, `${name}.har`)
  const context = await browser.newContext({
    colorScheme,
    viewport,
    recordHar: { path: harPath, mode: 'minimal', content: 'omit' },
    reducedMotion: 'reduce',
  })
  await context.addCookies([
    {
      name: themeCookieName,
      value: colorScheme,
      url: baseUrl,
    },
  ])
  const page = await context.newPage()
  const requestUrls = []
  const failedRequests = []
  const pageErrors = []
  page.on('request', (request) => requestUrls.push(request.url()))
  page.on('requestfailed', (request) => failedRequests.push(request.url()))
  page.on('pageerror', (error) => pageErrors.push(error.message))
  await installApiFixtures(page, initialized, authenticated)

  await page.goto(`${baseUrl}${pathname}`, { waitUntil: 'networkidle' })
  await page.waitForTimeout(250)

  const bodyText = await page.locator('body').innerText()
  assert.equal(bodyText.includes('504'), false, `${name} rendered a 504`)
  assert.equal(
    /Failed to (load|initialize)|Gateway Timeout/i.test(bodyText),
    false,
    `${name} rendered an API failure toast`
  )
  assert.equal(
    /Powerful API Management Platform|API Documentation/i.test(bodyText),
    false,
    `${name} exposed the retired API-platform footer copy`
  )
  assert.equal(
    pageErrors.length,
    0,
    `${name} page errors: ${pageErrors.join('; ')}`
  )
  assert.equal(
    failedRequests.length,
    0,
    `${name} failed requests: ${failedRequests.join(', ')}`
  )
  assertNoDefaultLogoRequest(requestUrls)
  assert.equal(
    await page.evaluate(
      (theme) => document.documentElement.classList.contains(theme),
      colorScheme
    ),
    true,
    `${name} did not apply the ${colorScheme} theme cookie`
  )

  const defaultMarks = await page.locator('svg[viewBox="0 0 56 56"]').count()
  assert.ok(defaultMarks > 0, `${name} did not render the inline default mark`)
  assert.equal(
    await page.locator('img[src="/logo.png"]').count(),
    0,
    `${name} emitted the legacy default image element`
  )
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth > window.innerWidth
    ),
    false,
    `${name} has horizontal overflow`
  )
  const restrictionNotice = page.getByText(accessPolicy, { exact: true })
  assert.equal(
    await restrictionNotice.count(),
    1,
    `${name} did not render exactly one access restriction notice`
  )
  assert.equal(
    await restrictionNotice.isVisible(),
    true,
    `${name} hid the access restriction notice`
  )

  if (pathname === '/') {
    const heroHeading = page.getByRole('heading', {
      name: 'LMM Forge',
      exact: true,
    })
    assert.ok(
      await heroHeading.count(),
      `${name} did not render the hero heading`
    )
    assert.equal(
      await heroHeading.evaluate(
        (element) => getComputedStyle(element).opacity
      ),
      '1',
      `${name} kept the hero heading invisible`
    )
    assert.ok(
      await page.getByText('Browse challenges', { exact: true }).count(),
      `${name} did not render the primary challenge action`
    )
    assert.ok(
      await page.getByText(challenge.title, { exact: true }).count(),
      `${name} did not render the live challenge fixture`
    )

    const illustration = page.locator('[data-forge-bounty-art="interactive"]')
    const illustrationBox = await illustration.boundingBox()
    assert.ok(
      illustrationBox &&
        illustrationBox.width >= 200 &&
        illustrationBox.height >= 200,
      `${name} did not render the Forge illustration at a usable size`
    )
    const illustrationColors = await illustration
      .locator('*')
      .evaluateAll((elements) =>
        elements.flatMap((element) => {
          const style = getComputedStyle(element)
          return [style.backgroundColor, style.fill, style.stroke]
        })
      )
    assert.ok(
      illustrationColors.includes('rgb(20, 20, 19)') &&
        illustrationColors.includes('rgb(250, 249, 245)'),
      `${name} rendered a blank Forge illustration`
    )

    const liveBoard = page.getByText('Live board', { exact: true })
    const liveBoardSectionTop = await liveBoard.evaluate(
      (element) => element.closest('section')?.getBoundingClientRect().top
    )
    assert.ok(
      typeof liveBoardSectionTop === 'number' &&
        liveBoardSectionTop < viewport.height,
      `${name} did not leave a visible hint of the next section`
    )
  }

  if (pathname === '/challenges') {
    assert.ok(
      await page.getByRole('heading', { name: 'Challenges' }).count(),
      `${name} did not render the challenge board heading`
    )
    assert.ok(
      await page.getByText(challenge.title, { exact: true }).count(),
      `${name} did not render the challenge board fixture`
    )
  }

  if (pathname === '/challenges/1') {
    assert.ok(
      await page.getByRole('heading', { name: challenge.title }).count(),
      `${name} did not render the challenge detail heading`
    )
    assert.ok(
      await page.getByRole('heading', { name: 'Delivery evidence' }).count(),
      `${name} did not render delivery evidence`
    )
    assert.ok(
      await page.getByRole('heading', { name: 'Settlement ledger' }).count(),
      `${name} did not render the settlement ledger`
    )
  }

  if (pathname === '/sign-in') {
    assert.ok(
      await page.getByRole('heading', { name: 'Sign in' }).count(),
      `${name} did not render the sign-in form`
    )
    assert.ok(
      (await page.locator('svg[viewBox="0 0 56 56"]').count()) > 0,
      `${name} did not render the inline default mark`
    )
  }

  if (pathname === '/pricing') {
    assert.equal(
      new URL(page.url()).pathname,
      '/pricing',
      `${name} did not keep the public access route available`
    )
    assert.ok(
      await page
        .getByRole('heading', {
          name: 'Developer access that grows with your work',
        })
        .count(),
      `${name} did not render the public access heading`
    )
  }

  if (pathname === '/workspace') {
    assert.ok(
      new URL(page.url()).pathname === '/getting-started',
      `${name} did not route an inactive account to getting started`
    )
    assert.ok(
      await page.getByRole('heading', { name: 'Getting started' }).count(),
      `${name} did not render the getting-started heading`
    )
    assert.equal(
      /Model Square|Console|Docs/.test(bodyText),
      false,
      `${name} exposed developer-console navigation before activation`
    )
  }

  await page.screenshot({
    path: path.join(outputDirectory, `${name}.png`),
    fullPage: true,
  })
  await context.close()
}

await mkdir(outputDirectory, { recursive: true })
const browser = await chromium.launch({ headless: true })
try {
  for (const colorScheme of ['light', 'dark']) {
    await verifyPage({
      name: `home-desktop-${colorScheme}`,
      pathname: '/',
      viewport: { width: 1440, height: 900 },
      colorScheme,
      initialized: true,
    })
    await verifyPage({
      name: `home-mobile-${colorScheme}`,
      pathname: '/',
      viewport: { width: 390, height: 844 },
      colorScheme,
      initialized: true,
    })
  }
  for (const viewport of [
    { name: 'desktop', width: 1440, height: 900 },
    { name: 'mobile', width: 390, height: 844 },
  ]) {
    await verifyPage({
      name: `challenges-${viewport.name}`,
      pathname: '/challenges',
      viewport,
      colorScheme: 'light',
      initialized: true,
    })
    await verifyPage({
      name: `challenge-detail-${viewport.name}`,
      pathname: '/challenges/1',
      viewport,
      colorScheme: 'light',
      initialized: true,
    })
  }
  await verifyPage({
    name: 'sign-in-access-policy',
    pathname: '/sign-in',
    viewport: { width: 1440, height: 900 },
    colorScheme: 'light',
    initialized: true,
  })
  await verifyPage({
    name: 'pricing-public-access',
    pathname: '/pricing',
    viewport: { width: 1440, height: 900 },
    colorScheme: 'light',
    initialized: true,
  })
  await verifyPage({
    name: 'workspace-access-policy',
    pathname: '/workspace',
    viewport: { width: 1440, height: 900 },
    colorScheme: 'light',
    initialized: true,
    authenticated: true,
  })
} finally {
  await browser.close()
}

for (const viewportName of ['desktop', 'mobile']) {
  const lightHash = await fileSha256(
    path.join(outputDirectory, `home-${viewportName}-light.png`)
  )
  const darkHash = await fileSha256(
    path.join(outputDirectory, `home-${viewportName}-dark.png`)
  )
  assert.notEqual(
    lightHash,
    darkHash,
    `${viewportName} light and dark screenshots are identical`
  )
}
