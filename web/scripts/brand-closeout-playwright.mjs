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
  '../test-results/brand-fix-review'
)
const baseUrl = process.env.BRAND_REVIEW_URL ?? 'http://127.0.0.1:4174'
const themeCookieName = 'vite-ui-theme'

function expectedHeroBackground(colorScheme) {
  return colorScheme === 'dark' ? 'rgb(20, 20, 19)' : 'rgb(250, 249, 245)'
}

async function fileSha256(filePath) {
  return createHash('sha256')
    .update(await readFile(filePath))
    .digest('hex')
}

const statusPayload = {
  success: true,
  data: {
    system_name: 'lmm.best',
    logo: '/logo.png',
    version: 'review-fixture',
    footer_html: '',
    demo_site_enabled: true,
    display_token_stat_enabled: false,
    display_in_currency: false,
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

async function installApiFixtures(page, initialized) {
  await page.route('**/api/**', async (route) => {
    const pathname = new URL(route.request().url()).pathname
    let json = { success: true, data: {} }

    if (pathname === '/api/status') json = statusPayload
    if (pathname === '/api/notice') json = { success: true, data: '' }
    if (pathname === '/api/home_page_content') {
      json = { success: true, data: '' }
    }
    if (pathname === '/api/setup') json = setupPayload(initialized)
    if (pathname === '/api/user/auth/refresh') {
      json = { success: false, message: 'anonymous' }
    }

    await route.fulfill({ contentType: 'application/json', json })
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
}) {
  const harPath = path.join(outputDirectory, `${name}.har`)
  const context = await browser.newContext({
    colorScheme,
    viewport,
    recordHar: { path: harPath, mode: 'full' },
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
  await installApiFixtures(page, initialized)

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

  if (pathname === '/') {
    const heroHeading = page.getByRole('heading', {
      name: /Token Not Included/i,
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
    assert.equal(
      await heroHeading.evaluate(
        (element) =>
          getComputedStyle(element.closest('section')).backgroundColor
      ),
      expectedHeroBackground(colorScheme),
      `${name} has the wrong ${colorScheme} hero background`
    )
    assert.ok(
      await page.getByText('How It Works', { exact: true }).count(),
      `${name} did not render the onboarding section`
    )
    assert.ok(
      await page.getByText('Open Source', { exact: true }).count(),
      `${name} did not render the CTA`
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
  await verifyPage({
    name: 'sign-in-default-brand',
    pathname: '/sign-in',
    viewport: { width: 1440, height: 900 },
    colorScheme: 'light',
    initialized: true,
  })
  await verifyPage({
    name: 'setup-default-brand',
    pathname: '/setup',
    viewport: { width: 1440, height: 900 },
    colorScheme: 'light',
    initialized: false,
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
