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
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { createServer } from 'node:http'
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname, extname, join, normalize, resolve } from 'node:path'

const require = createRequire(import.meta.url)
const measurements = {}
const appRoot = resolve(import.meta.dirname, '..')
const distRoot = join(appRoot, 'dist')
const evidenceRoot = resolve(
  process.env.OAUTH_UI_EVIDENCE_DIR || join(appRoot, '../../.scratch/oauth-ui/evidence')
)

if (!existsSync(join(distRoot, 'index.html'))) {
  throw new Error('apps/web/dist is missing; run `bun run build` before the OAuth UI browser test')
}

function loadPlaywright() {
  try {
    return require('playwright')
  } catch {
    const candidates = [
      join(
        execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim(),
        'playwright'
      ),
      dirname(realpathSync(execFileSync('which', ['playwright'], { encoding: 'utf8' }).trim())),
    ]
    const packageRoot = candidates.find((candidate) =>
      existsSync(join(candidate, 'package.json'))
    )
    if (!packageRoot) {
      throw new Error('Playwright is required for the OAuth UI browser test')
    }
    return require(packageRoot)
  }
}

const mimeTypes = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.ico', 'image/x-icon'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml'],
  ['.webp', 'image/webp'],
  ['.woff2', 'font/woff2'],
])

function startStaticServer() {
  const server = createServer((request, response) => {
    const requestPath = new URL(request.url || '/', 'http://127.0.0.1').pathname
    const normalizedPath = normalize(decodeURIComponent(requestPath)).replace(
      /^(\.\.[/\\])+/,
      ''
    )
    let filePath = join(distRoot, normalizedPath)
    if (!filePath.startsWith(distRoot) || !existsSync(filePath)) {
      filePath = join(distRoot, 'index.html')
    }
    const body = readFileSync(filePath)
    response.writeHead(200, {
      'Cache-Control': 'no-store',
      'Content-Type': mimeTypes.get(extname(filePath)) || 'application/octet-stream',
    })
    response.end(body)
  })
  return new Promise((resolveServer, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => resolveServer(server))
  })
}

function authBundle() {
  const now = Math.floor(Date.now() / 1000)
  return {
    access_token: 'browser-e2e-access-token',
    token_type: 'Bearer',
    access_expires_at: now + 600,
    user: { id: 71, username: 'forge-browser-user', role: 1 },
    session: {
      sid: 'oauth-ui-browser-session',
      current: true,
      login_method: 'password',
      ip: '127.0.0.1',
      user_agent: 'Playwright',
      created_at: now - 60,
      last_active_at: now,
      expires_at: now + 3600,
    },
  }
}

async function installApiMocks(page, scenario = {}) {
  if (process.env.DEBUG_OAUTH_UI) {
    page.on('console', (message) => process.stderr.write(`console ${message.type()} ${message.text()}\n`))
    page.on('request', (request) => {
      if (request.url().includes('/api/')) {
        process.stderr.write(`request ${request.method()} ${request.url()}\n`)
      }
    })
  }
  await page.route('http://127.0.0.1:49152/**', (route) =>
    route.fulfill({ status: 200, contentType: 'text/plain', body: 'CLI callback received' })
  )
  await page.route('**/api/**', async (route) => {
    const request = route.request()
    const url = new URL(request.url())
    const json = (body, status = 200) =>
      route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })

    if (url.pathname === '/api/setup') {
      return json({
        success: true,
        data: { status: true, root_init: true, database_type: 'postgresql' },
      })
    }
    if (url.pathname === '/api/user/auth/refresh') {
      return json({ success: true, message: '', data: authBundle() })
    }
    if (url.pathname === '/api/oauth/authorization/request-token') {
      if (request.method() === 'GET') {
        if (scenario.previewDelay) {
          await new Promise((resolveDelay) =>
            setTimeout(resolveDelay, scenario.previewDelay)
          )
        }
        if (scenario.previewError) {
          return json({ success: false, message: 'expired' }, 400)
        }
        return json({
          success: true,
          data: {
            client_id: 'lmm-api-rs',
            client_name: 'lmm-api-rs',
            redirect_uri: 'http://127.0.0.1:49152/oauth/callback',
            scopes: [
              'api_keys:list',
              'api_keys:create',
              'api_keys:reveal',
              'cc_switch:import',
            ],
            expires_at: new Date(Date.now() + 5 * 60_000).toISOString(),
          },
        })
      }
      const decision = request.postDataJSON()
      const target = scenario.unsafeDecision
        ? 'https://evil.example/callback?code=must-not-leak'
        : `http://127.0.0.1:49152/oauth/callback?${
            decision.approve
              ? `code=${'c'.repeat(43)}&state=${'s'.repeat(43)}`
              : `error=access_denied&state=${'s'.repeat(43)}`
          }`
      return json({ success: true, data: { redirect_uri: target } })
    }
    if (url.pathname === '/api/oauth/device') {
      const decision = request.postDataJSON()
      assert.equal(decision.user_code, 'ABCD-EFGH')
      if (scenario.deviceDelay) {
        await new Promise((resolveDelay) =>
          setTimeout(resolveDelay, scenario.deviceDelay)
        )
      }
      if (scenario.deviceError) {
        return json({ success: false, message: 'expired' }, 400)
      }
      return json({ success: true, data: { approved: Boolean(decision.approve) } })
    }
    return json({ success: true, data: {} })
  })
}

async function assertNoHorizontalOverflow(page) {
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= document.documentElement.clientWidth
    ),
    true
  )
}

async function captureEvidence(page, filename) {
  let firstError
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await page.screenshot({
        path: join(evidenceRoot, filename),
        fullPage: true,
      })
      return
    } catch (error) {
      firstError ??= error
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 100))
    }
  }
  throw firstError
}

await mkdir(evidenceRoot, { recursive: true })
const server = await startStaticServer()
const address = server.address()
assert(address && typeof address === 'object')
const origin = `http://127.0.0.1:${address.port}`
const { chromium } = loadPlaywright()
const browser = await chromium.launch({ headless: true })

try {
  const desktop = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    locale: 'en-US',
    colorScheme: 'light',
    reducedMotion: 'reduce',
  })
  const consentPage = await desktop.newPage()
  await installApiMocks(consentPage)
  const consentStartedAt = Date.now()
  await consentPage.goto(`${origin}/oauth/consent?request=request-token`)
  try {
    await consentPage.getByRole('button', { name: 'Allow access' }).waitFor()
  } catch (error) {
    const pageText = await consentPage.locator('body').innerText()
    throw new Error(`Consent page did not become ready at ${consentPage.url()}: ${pageText}`, {
      cause: error,
    })
  }
  measurements.consentReadyMs = Date.now() - consentStartedAt
  await consentPage.getByText('127.0.0.1:49152').waitFor()
  await assertNoHorizontalOverflow(consentPage)
  await captureEvidence(consentPage, 'oauth-consent-desktop-light.png')
  const consentDecisionStartedAt = Date.now()
  await consentPage.getByRole('button', { name: 'Allow access' }).click()
  await consentPage.waitForURL(/127\.0\.0\.1:49152\/oauth\/callback/)
  measurements.consentDecisionMs = Date.now() - consentDecisionStartedAt
  assert.equal(
    new URL(consentPage.url()).searchParams.get('state'),
    's'.repeat(43)
  )

  const missingPage = await desktop.newPage()
  await installApiMocks(missingPage)
  await missingPage.goto(`${origin}/oauth/consent`)
  await missingPage.getByText('Authorization request missing').waitFor()
  await captureEvidence(missingPage, 'oauth-consent-missing.png')

  const blockedPage = await desktop.newPage()
  await installApiMocks(blockedPage, { unsafeDecision: true })
  await blockedPage.goto(`${origin}/oauth/consent?request=request-token`)
  await blockedPage.getByRole('button', { name: 'Allow access' }).click()
  await blockedPage.getByText('Unsafe callback blocked').waitFor()
  assert.equal(new URL(blockedPage.url()).origin, origin)
  await captureEvidence(blockedPage, 'oauth-consent-callback-blocked.png')

  const errorPage = await desktop.newPage()
  await installApiMocks(errorPage, { previewError: true })
  await errorPage.goto(`${origin}/oauth/consent?request=request-token`)
  await errorPage.getByText('Authorization request unavailable').waitFor()
  await errorPage.getByRole('button', { name: 'Retry' }).waitFor()
  await captureEvidence(errorPage, 'oauth-consent-error.png')

  const loadingPage = await desktop.newPage()
  await installApiMocks(loadingPage, { previewDelay: 800 })
  const loadingNavigation = loadingPage.goto(
    `${origin}/oauth/consent?request=request-token`
  )
  await loadingPage
    .getByLabel('Loading authorization request')
    .waitFor()
  await captureEvidence(loadingPage, 'oauth-consent-loading.png')
  await loadingNavigation
  await loadingPage.getByRole('button', { name: 'Allow access' }).waitFor()

  const desktopDevicePage = await desktop.newPage()
  await installApiMocks(desktopDevicePage)
  await desktopDevicePage.goto(`${origin}/oauth/device?user_code=abcd-efgh`)
  await desktopDevicePage.getByRole('button', { name: 'Connect device' }).waitFor()
  await assertNoHorizontalOverflow(desktopDevicePage)
  await captureEvidence(desktopDevicePage, 'oauth-device-desktop-light.png')
  await desktop.close()

  const dark = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    locale: 'en-US',
    colorScheme: 'dark',
    reducedMotion: 'reduce',
  })
  await dark.addCookies([
    { name: 'vite-ui-theme', value: 'dark', url: origin },
  ])
  const darkPage = await dark.newPage()
  await installApiMocks(darkPage)
  await darkPage.goto(`${origin}/oauth/consent?request=request-token`)
  await darkPage.getByRole('button', { name: 'Allow access' }).waitFor()
  await captureEvidence(darkPage, 'oauth-consent-desktop-dark.png')
  await dark.close()

  const mobile = await browser.newContext({
    viewport: { width: 375, height: 812 },
    locale: 'en-US',
    colorScheme: 'light',
    reducedMotion: 'reduce',
  })
  const devicePage = await mobile.newPage()
  await installApiMocks(devicePage, { deviceDelay: 500 })
  await devicePage.goto(`${origin}/oauth/device?user_code=abcd-efgh`)
  await devicePage.getByRole('button', { name: 'Connect device' }).waitFor()
  assert.equal(await devicePage.getByLabel('Device code').inputValue(), 'ABCD-EFGH')
  await assertNoHorizontalOverflow(devicePage)
  await captureEvidence(devicePage, 'oauth-device-mobile-light.png')

  const mobileConsentPage = await mobile.newPage()
  await installApiMocks(mobileConsentPage)
  await mobileConsentPage.goto(
    `${origin}/oauth/consent?request=request-token`
  )
  await mobileConsentPage.getByRole('button', { name: 'Allow access' }).waitFor()
  await assertNoHorizontalOverflow(mobileConsentPage)
  await captureEvidence(mobileConsentPage, 'oauth-consent-mobile-light.png')
  const deviceDecisionStartedAt = Date.now()
  await devicePage.getByRole('button', { name: 'Connect device' }).click()
  await captureEvidence(devicePage, 'oauth-device-submitting-mobile.png')
  await devicePage.getByText('Device connected').waitFor()
  measurements.deviceDecisionMs = Date.now() - deviceDecisionStartedAt
  await captureEvidence(devicePage, 'oauth-device-success-mobile.png')

  const emptyDevicePage = await mobile.newPage()
  await installApiMocks(emptyDevicePage)
  await emptyDevicePage.goto(`${origin}/oauth/device`)
  await emptyDevicePage.getByLabel('Device code').waitFor()
  assert.equal(await emptyDevicePage.getByLabel('Device code').inputValue(), '')
  await captureEvidence(emptyDevicePage, 'oauth-device-empty-mobile.png')

  const failedDevicePage = await mobile.newPage()
  await installApiMocks(failedDevicePage, { deviceError: true })
  await failedDevicePage.goto(`${origin}/oauth/device?user_code=abcd-efgh`)
  await failedDevicePage.getByRole('button', { name: 'Connect device' }).click()
  await failedDevicePage.getByText('Could not confirm this code').waitFor()
  await captureEvidence(failedDevicePage, 'oauth-device-error-mobile.png')
  await mobile.close()

  await writeFile(
    join(evidenceRoot, 'oauth-ui-measurements.json'),
    `${JSON.stringify(measurements, null, 2)}\n`
  )
  process.stdout.write(`OAuth UI browser evidence written to ${evidenceRoot}\n`)
} finally {
  await browser.close()
  await new Promise((resolveClose, reject) =>
    server.close((error) => (error ? reject(error) : resolveClose()))
  )
}
