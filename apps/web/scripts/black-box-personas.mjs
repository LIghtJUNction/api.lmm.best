#!/usr/bin/env node

import { lstat, readFile, realpath, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'

const require = createRequire(import.meta.url)
const playwrightEntry = (() => {
  try {
    return require.resolve('playwright')
  } catch {
    const nodePrefix = path.resolve(path.dirname(process.execPath), '../lib')
    try {
      return require.resolve('playwright', { paths: [nodePrefix] })
    } catch (error) {
      throw new Error(
        'Playwright is not available locally; use the machine-provided Playwright (no repository dependency is added).',
        { cause: error }
      )
    }
  }
})()
const { chromium } = (await import(playwrightEntry)).default

const baseUrl = process.env.PERSONA_REVIEW_URL ?? 'http://127.0.0.1:4174'
const configuredWorkspace = process.env.PERSONA_DEPLOY_WORKSPACE
const configuredOutputDirectory = process.env.PERSONA_OUTPUT_DIR
const parsedBaseUrl = new URL(baseUrl)
const baseOrigin = parsedBaseUrl.origin

if (
  parsedBaseUrl.protocol !== 'http:' ||
  parsedBaseUrl.hostname !== '127.0.0.1' ||
  parsedBaseUrl.port !== '4174'
) {
  throw new Error('PERSONA_REVIEW_URL must be exactly http://127.0.0.1:4174')
}
if (!configuredWorkspace || !configuredOutputDirectory) {
  throw new Error(
    'PERSONA_DEPLOY_WORKSPACE and PERSONA_OUTPUT_DIR are required'
  )
}

async function validateArtifactWorkspace(workspaceInput, outputInput) {
  if (!path.isAbsolute(workspaceInput) || !path.isAbsolute(outputInput)) {
    throw new Error(
      'deployment workspace and output directory must be absolute'
    )
  }
  const resolvedWorkspace = await realpath(workspaceInput)
  const resolvedOutput = await realpath(outputInput)
  if (workspaceInput !== resolvedWorkspace || outputInput !== resolvedOutput) {
    throw new Error(
      'deployment workspace and output directory must be canonical'
    )
  }
  if (
    resolvedWorkspace === '/' ||
    resolvedWorkspace === '/tmp' ||
    resolvedWorkspace.startsWith('/tmp/') ||
    resolvedWorkspace === '/var/tmp' ||
    resolvedWorkspace.startsWith('/var/tmp/')
  ) {
    throw new Error('deployment workspace uses a forbidden path')
  }
  if (
    resolvedOutput === resolvedWorkspace ||
    !resolvedOutput.startsWith(`${resolvedWorkspace}${path.sep}`)
  ) {
    throw new Error('output directory must be a strict workspace descendant')
  }
  for (const candidate of [resolvedWorkspace, resolvedOutput]) {
    const info = await lstat(candidate)
    if (!info.isDirectory() || info.isSymbolicLink()) {
      throw new Error('workspace paths must be real directories')
    }
  }
  const markerPath = path.join(resolvedWorkspace, '.lmm-deploy-workspace')
  const markerInfo = await lstat(markerPath)
  if (!markerInfo.isFile() || markerInfo.isSymbolicLink()) {
    throw new Error('deployment workspace marker is missing or unsafe')
  }
  const marker = Object.create(null)
  const markerText = await readFile(markerPath, 'utf8')
  for (const line of markerText.trimEnd().split('\n')) {
    const separator = line.indexOf('=')
    if (separator <= 0)
      throw new Error('deployment workspace marker is malformed')
    const key = line.slice(0, separator)
    const value = line.slice(separator + 1)
    if (
      ![
        'format',
        'deployment_id',
        'role',
        'workspace',
        'created_at_utc',
      ].includes(key)
    ) {
      throw new Error('deployment workspace marker contains an unknown key')
    }
    if (Object.hasOwn(marker, key)) {
      throw new Error('deployment workspace marker has duplicates')
    }
    marker[key] = value
  }
  if (
    marker.format !== '1' ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(marker.deployment_id || '') ||
    marker.role !== 'controller' ||
    marker.workspace !== resolvedWorkspace ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(marker.created_at_utc || '')
  ) {
    throw new Error('deployment workspace marker identity does not match')
  }
  return { workspace: resolvedWorkspace, output: resolvedOutput }
}

const artifactWorkspace = await validateArtifactWorkspace(
  configuredWorkspace,
  configuredOutputDirectory
)
const outputDirectory = artifactWorkspace.output

const runId = `personas-${Date.now()}-${process.pid}`
const screenshotPath = (name) =>
  path.join(outputDirectory, `${runId}-${name}.png`)
const reportPath = path.join(outputDirectory, `${runId}-report.json`)
const policyPhrases = [
  /\b(?:proxy|proxies|relay|intermediary|upstream)\b/giu,
  /\bunified\s+(?:interface|api)\b/giu,
  /\b(?:single|one)[ -]key\b/giu,
  /\bmultiple\s+providers\b/giu,
  /\bacross\s+providers\b/giu,
  /\baggregation\b/giu,
  /\b(?:route|forward)\s+(?:the\s+)?requests?\s+to\s+providers?\b/giu,
  /\bselected\s+provider\b/giu,
  /\bresale\b/giu,
  /中转|代理|中继|中介|上游|统一(?:接口|API)|单一密钥|一个密钥|多(?:个)?供应商|跨供应商|聚合|将请求(?:路由|转发)给供应商|选定的供应商|转售/gu,
]
const valueLanguage =
  /developer access|pay as you go|usage credit|create an account|access options|开放|开发者|充值|注册/i
const signupCtaLanguage =
  /create (?:an )?account|sign up|get started|start now|register|创建账户|注册|开始使用/i

function sanitizeUrl(rawUrl) {
  const url = new URL(rawUrl)
  return { origin: url.origin, path: url.pathname }
}

function boundedContext(text, index, matchLength) {
  const start = Math.max(0, index - 80)
  const end = Math.min(text.length, index + matchLength + 80)
  return text.slice(start, end)
}

function findPolicyPhrases(pageName, source, text) {
  const findings = []
  for (const pattern of policyPhrases) {
    pattern.lastIndex = 0
    for (const match of text.matchAll(pattern)) {
      findings.push({
        page: pageName,
        source,
        phrase: match[0],
        context: boundedContext(text, match.index ?? 0, match[0].length),
      })
    }
  }
  return findings
}

async function inspectDocument(page) {
  return page.evaluate(() => {
    const normalize = (value) => (value || '').replaceAll(/\s+/g, ' ').trim()
    const accessibleNames = [
      ...document.querySelectorAll('a,button,input,select,textarea,img,[role]'),
    ]
      .map((element) => {
        const labelledBy = element.getAttribute('aria-labelledby')
        const labelledText = labelledBy
          ? labelledBy
              .split(/\s+/)
              .map(
                (id) =>
                  document.querySelector(`#${CSS.escape(id)}`)?.textContent ||
                  ''
              )
              .join(' ')
          : ''
        return normalize(
          element.getAttribute('aria-label') ||
            labelledText ||
            element.getAttribute('alt') ||
            element.getAttribute('title') ||
            element.textContent ||
            element.getAttribute('placeholder') ||
            ''
        )
      })
      .filter(Boolean)
    const destinations = [
      ...document.querySelectorAll('header a[href], footer a[href]'),
    ].map((anchor) => anchor.href)
    const signupCtas = [...document.querySelectorAll('a[href],button')]
      .map((element) => ({
        label: normalize(
          element.getAttribute('aria-label') || element.textContent || ''
        ),
        href: element instanceof HTMLAnchorElement ? element.href : '',
      }))
      .filter(
        (item) =>
          /create (?:an )?account|sign up|get started|start now|register|创建账户|注册|开始使用/i.test(
            item.label
          ) || /\/(?:sign-up|signup|register)(?:\/|$)/.test(item.href)
      )
    return {
      visibleText: normalize(document.body?.innerText || ''),
      description: normalize(
        document
          .querySelector('meta[name="description"]')
          ?.getAttribute('content') || ''
      ),
      accessibleNames,
      destinations,
      signupCtas,
    }
  })
}

async function capture(page, name, pathname) {
  const requestedUrl = new URL(pathname, baseUrl).toString()
  try {
    const response = await page.goto(requestedUrl, {
      waitUntil: 'domcontentloaded',
      timeout: 15_000,
    })
    await page.waitForTimeout(500)
    const documentState = await inspectDocument(page)
    await page.screenshot({ path: screenshotPath(name), fullPage: true })
    return {
      name,
      requestedUrl,
      finalUrl: page.url(),
      status: response?.status() ?? null,
      title: await page.title().catch(() => ''),
      ...documentState,
    }
  } catch (error) {
    await page
      .screenshot({ path: screenshotPath(name), fullPage: true })
      .catch(() => {})
    return {
      name,
      requestedUrl,
      finalUrl: page.url(),
      status: null,
      title: '',
      visibleText: '',
      description: '',
      accessibleNames: [],
      destinations: [],
      signupCtas: [],
      runtime: 'NEEDS_RUNTIME',
      error: String(error).slice(0, 500),
    }
  }
}

function mutationAllowed(method, pathname) {
  if (method === 'POST') {
    return (
      [
        '/api/user/register',
        '/api/user/login',
        '/api/user/auth/refresh',
        '/api/token/',
      ].includes(pathname) || /^\/api\/token\/\d+\/key$/.test(pathname)
    )
  }
  return ['GET', 'HEAD', 'OPTIONS'].includes(method)
}

function installRouting(context, metrics, blockMutations = true) {
  return context.route('**/*', async (route) => {
    const request = route.request()
    let requestUrl
    try {
      requestUrl = new URL(request.url())
    } catch {
      await route.abort('blockedbyclient')
      return
    }
    if (requestUrl.origin !== baseOrigin) {
      metrics.blockedExternal.push({
        method: request.method(),
        ...sanitizeUrl(request.url()),
      })
      await route.abort('blockedbyclient')
      return
    }
    const sensitive =
      /\/(?:payment|redeem|redemption|checkout|transfer|creem|waffo|pancake)(?:\/|$)/i.test(
        requestUrl.pathname
      )
    if (
      sensitive ||
      (blockMutations &&
        !mutationAllowed(request.method(), requestUrl.pathname))
    ) {
      metrics.blockedMutations.push({
        method: request.method(),
        ...sanitizeUrl(request.url()),
      })
      await route.abort('blockedbyclient')
      return
    }
    await route.continue()
  })
}

function attachMetrics(page, metrics) {
  page.on('request', (request) => {
    metrics.requests.push({
      method: request.method(),
      resourceType: request.resourceType(),
      ...sanitizeUrl(request.url()),
    })
  })
  page.on('response', (response) => {
    const responseUrl = new URL(response.url())
    metrics.responses.push({
      method: response.request().method(),
      status: response.status(),
      ...sanitizeUrl(response.url()),
    })
    const expectedAnonymousRefresh =
      response.status() === 401 &&
      responseUrl.pathname === '/api/user/auth/refresh'
    if (response.status() >= 400 && !expectedAnonymousRefresh) {
      metrics.failedResponses.push({
        status: response.status(),
        ...sanitizeUrl(response.url()),
      })
    }
  })
  page.on('requestfailed', (request) => {
    metrics.failedRequests.push({
      method: request.method(),
      ...sanitizeUrl(request.url()),
    })
  })
  page.on('pageerror', (error) =>
    metrics.pageErrors.push(String(error).slice(0, 500))
  )
  page.on('console', (message) => {
    if (['error', 'warning'].includes(message.type())) {
      metrics.console.push({
        type: message.type(),
        text: message.text().slice(0, 500),
      })
    }
  })
}

function createMetrics() {
  return {
    requests: [],
    responses: [],
    blockedExternal: [],
    blockedMutations: [],
    failedRequests: [],
    failedResponses: [],
    pageErrors: [],
    console: [],
  }
}

function unexpectedMutationEvidence(allMetrics) {
  const mutations = allMetrics
    .flatMap((item) => item.requests)
    .filter((request) => !['GET', 'HEAD', 'OPTIONS'].includes(request.method))
  const count = (pathname) =>
    mutations.filter((request) => request.path === pathname).length
  const revealCount = mutations.filter((request) =>
    /^\/api\/token\/\d+\/key$/.test(request.path)
  ).length
  const unexpected = mutations.filter(
    (request) => !mutationAllowed(request.method, request.path)
  )
  if (count('/api/user/register') !== 2) {
    unexpected.push({ reason: 'registration count mismatch' })
  }
  if (count('/api/user/login') !== 2) {
    unexpected.push({ reason: 'login count mismatch' })
  }
  if (count('/api/token/') !== 1) {
    unexpected.push({ reason: 'token creation count mismatch' })
  }
  if (revealCount !== 1) {
    unexpected.push({ reason: 'token reveal count mismatch' })
  }
  if (count('/api/user/auth/refresh') < 2) {
    unexpected.push({ reason: 'bootstrap refresh count mismatch' })
  }
  return unexpected
}

async function runPersonaA(browser) {
  const context = await browser.newContext({
    serviceWorkers: 'block',
    viewport: { width: 1440, height: 1000 },
  })
  const metrics = createMetrics()
  installRouting(context, metrics)
  const page = await context.newPage()
  attachMetrics(page, metrics)

  const pages = {}
  const queue = [
    ['root', '/'],
    ['pricing', '/pricing'],
    ['sign-up', '/sign-up'],
    ['user-agreement', '/user-agreement'],
    ['privacy-policy', '/privacy-policy'],
    ['challenges', '/challenges'],
  ]
  const capturedPaths = new Set()
  while (queue.length > 0) {
    const [name, pathname] = queue.shift()
    const normalizedPath = new URL(pathname, baseUrl).pathname
    if (capturedPaths.has(normalizedPath)) continue
    capturedPaths.add(normalizedPath)
    const result = await capture(page, name, pathname)
    pages[name] = result
    for (const destination of result.destinations) {
      const url = new URL(destination, baseUrl)
      if (url.origin !== baseOrigin) continue
      const destinationPath = url.pathname
      if (
        capturedPaths.has(destinationPath) ||
        /^\/(?:api|wallet|keys|dashboard|profile|support|getting-started)(?:\/|$)/.test(
          destinationPath
        )
      ) {
        continue
      }
      queue.push([
        `public-${destinationPath.replaceAll(/^\/+|\/+$/g, '').replaceAll(/[^a-z0-9]+/gi, '-') || 'root'}`,
        destinationPath,
      ])
    }
  }

  const jargonFindings = Object.values(pages).flatMap((item) => {
    const sources = [
      ['visible-text', item.visibleText],
      ['title', item.title],
      ['description', item.description],
      ['accessible-names', item.accessibleNames.join(' | ')],
    ]
    return sources.flatMap(([source, text]) =>
      findPolicyPhrases(item.name, source, text)
    )
  })
  const intendedCtas = Object.values(pages).map((item) => ({
    page: item.name,
    count: item.signupCtas.length,
    labels: item.signupCtas
      .map((cta) => cta.label)
      .filter((label) => signupCtaLanguage.test(label)),
  }))
  const valuePages = Object.values(pages)
    .filter((item) => valueLanguage.test(item.visibleText))
    .map((item) => item.name)
  const legalDisclosurePages = ['user-agreement', 'privacy-policy'].filter(
    (name) =>
      /third-party|provider|processing|retain|inputs|payment|law/i.test(
        pages[name]?.visibleText || ''
      )
  )
  const requiredCtaPages = ['root', 'pricing', 'sign-up']
  const hasRuntimeGap = Object.values(pages).some(
    (item) => item.runtime === 'NEEDS_RUNTIME'
  )
  const failed =
    jargonFindings.length > 0 ||
    Object.values(pages).some((item) => item.status !== 200) ||
    metrics.blockedExternal.length > 0 ||
    metrics.failedResponses.length > 0 ||
    requiredCtaPages.some(
      (name) => (pages[name]?.signupCtas.length || 0) === 0
    ) ||
    valuePages.length < 2 ||
    legalDisclosurePages.length !== 2
  let status = 'PASS'
  if (hasRuntimeGap) status = 'NEEDS_RUNTIME'
  else if (failed) status = 'FAIL'
  await context.close()
  return {
    status,
    pages,
    jargonFindings,
    intendedCtas,
    valuePages,
    legalDisclosurePages,
    metrics,
  }
}

function validSelfData(data, expected) {
  const onboarding = data.onboarding
  return (
    Number.isInteger(data.id) &&
    typeof data.username === 'string' &&
    data?.developer_access_granted === true &&
    onboarding &&
    typeof onboarding === 'object' &&
    onboarding.paid_activation_complete === false &&
    onboarding.credential_complete === expected.credentialComplete &&
    onboarding.stage === expected.stage
  )
}

async function requireActionResponse(response, label) {
  if (!response || response.status() >= 400) {
    throw new Error(`${label} HTTP response failed`)
  }
  const payload = await response.json().catch(() => null)
  if (!payload || typeof payload !== 'object' || payload.success !== true) {
    throw new Error(`${label} API payload is malformed or unsuccessful`)
  }
  return payload
}

async function requireDataResponse(response, validateData, label) {
  const payload = await requireActionResponse(response, label)
  if (!Object.hasOwn(payload, 'data') || !validateData(payload.data)) {
    throw new Error(`${label} API data is missing or malformed`)
  }
  return payload.data
}

function waitForApiResponse(page, method, pathPattern) {
  return page.waitForResponse(
    (response) =>
      response.request().method() === method &&
      (typeof pathPattern === 'string'
        ? new URL(response.url()).pathname === pathPattern
        : pathPattern.test(new URL(response.url()).pathname)),
    { timeout: 10_000 }
  )
}

function validAuthBundle(data) {
  return Boolean(
    data &&
    typeof data === 'object' &&
    typeof data.access_token === 'string' &&
    data.access_token.length > 0 &&
    data.user &&
    Number.isInteger(data.user.id) &&
    data.session &&
    typeof data.session.sid === 'string' &&
    data.session.sid.length > 0
  )
}

function validTokenListData(data) {
  return Boolean(
    data &&
    typeof data === 'object' &&
    Array.isArray(data.items) &&
    Number.isInteger(data.total) &&
    Number.isInteger(data.page) &&
    Number.isInteger(data.page_size) &&
    data.items.every(
      (item) =>
        item &&
        typeof item === 'object' &&
        Number.isInteger(item.id) &&
        typeof item.name === 'string'
    )
  )
}

async function sanitizeRevealSurface(page) {
  return page.evaluate(() => {
    const tokenPattern = /sk-[A-Za-z0-9_-]{12,}/
    for (const input of document.querySelectorAll('input,textarea')) {
      if (tokenPattern.test(input.value)) input.value = ''
    }
    for (const element of document.querySelectorAll(
      '[role="dialog"], [data-radix-popper-content-wrapper]'
    )) {
      if (
        /Full API Key/i.test(element.textContent || '') ||
        tokenPattern.test(element.textContent || '')
      ) {
        element.remove()
      }
    }
    const text = document.body?.innerText || ''
    const values = [...document.querySelectorAll('input,textarea')].map(
      (input) => input.value
    )
    return (
      !/Full API Key/i.test(text) &&
      !tokenPattern.test(text) &&
      !values.some((value) => tokenPattern.test(value))
    )
  })
}

async function safeScreenshot(page, name) {
  if (!(await sanitizeRevealSurface(page))) {
    return { written: false, reason: 'secret sanitization could not be proven' }
  }
  await page.screenshot({ path: screenshotPath(name) })
  return { written: true }
}

async function registerThroughUI(page, credentials) {
  await page.goto(new URL('/sign-up', baseUrl).toString(), {
    waitUntil: 'domcontentloaded',
  })
  await page.getByLabel('Username', { exact: true }).fill(credentials.username)
  await page.getByLabel('Password', { exact: true }).fill(credentials.password)
  await page
    .getByLabel('Confirm password', { exact: true })
    .fill(credentials.password)
  const email = page.locator('input[type=email]:visible')
  if ((await email.count()) > 0) await email.first().fill(credentials.email)
  for (const checkbox of await page
    .locator('input[type=checkbox]:visible')
    .all()) {
    if (!(await checkbox.isChecked())) await checkbox.check()
  }
  const responsePromise = page.waitForResponse(
    (response) =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname === '/api/user/register'
  )
  await page
    .getByRole('button', { name: 'Create account', exact: true })
    .click()
  const response = await responsePromise
  await page.waitForURL(/\/sign-in(?:\/|$)/, { timeout: 10_000 })
  await requireActionResponse(response, 'registration')
  return true
}

async function loginThroughUI(page, credentials) {
  const username = page.getByLabel('Username or Email', { exact: true })
  await username.fill(credentials.username)
  await page.getByLabel('Password', { exact: true }).fill(credentials.password)
  const responsePromise = page.waitForResponse(
    (response) =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname === '/api/user/login'
  )
  await page.getByRole('button', { name: 'Sign in', exact: true }).click()
  const response = await responsePromise
  await page.waitForURL(/\/(?:getting-started|dashboard|wallet|keys)(?:\/|$)/, {
    timeout: 10_000,
  })
  await requireDataResponse(response, validAuthBundle, 'login')
  return true
}

async function runSecondUserIsolation(browser, firstTokenName, suffix) {
  const context = await browser.newContext({ serviceWorkers: 'block' })
  const metrics = createMetrics()
  installRouting(context, metrics)
  const page = await context.newPage()
  attachMetrics(page, metrics)
  const credentials = {
    username: `preview_isolation_${suffix}`,
    email: `preview_isolation_${suffix}@example.invalid`,
    password: 'PreviewPass123!',
  }
  try {
    const registered = await registerThroughUI(page, credentials)
    const loggedIn = registered && (await loginThroughUI(page, credentials))
    if (!loggedIn) {
      return {
        verified: false,
        reason: 'second user authentication failed',
        metrics,
      }
    }
    await page.goto(new URL('/getting-started', baseUrl).toString(), {
      waitUntil: 'domcontentloaded',
    })
    const refreshResponsePromise = waitForApiResponse(
      page,
      'POST',
      '/api/user/auth/refresh'
    )
    const selfResponsePromise = waitForApiResponse(
      page,
      'GET',
      '/api/user/self'
    )
    const listResponsePromise = waitForApiResponse(page, 'GET', '/api/token/')
    await page.reload({ waitUntil: 'domcontentloaded' })
    await requireDataResponse(
      await refreshResponsePromise,
      validAuthBundle,
      'second-user refresh'
    )
    await page.waitForURL(/\/getting-started(?:\/|$)/, { timeout: 10_000 })
    const selfData = await requireDataResponse(
      await selfResponsePromise,
      (data) =>
        validSelfData(data, { credentialComplete: false, stage: 'credential' }),
      'second-user self'
    )
    if (selfData.username !== credentials.username) {
      return {
        verified: false,
        reason: 'second-user identity mismatch',
        metrics,
      }
    }
    await page.goto(new URL('/keys', baseUrl).toString(), {
      waitUntil: 'domcontentloaded',
    })
    const listData = await requireDataResponse(
      await listResponsePromise,
      validTokenListData,
      'second-user token list'
    )
    const items = listData.items
    const observedFirstCredential = items.some(
      (item) => item.name === firstTokenName
    )
    const containsCredentialMaterial = items.some(
      (item) =>
        /acceptance-credential-/i.test(item.name) ||
        (typeof item.key === 'string' && item.key.length > 0)
    )
    return {
      verified: !observedFirstCredential && !containsCredentialMaterial,
      observedFirstCredential,
      metrics,
    }
  } catch (error) {
    return { verified: false, reason: String(error).slice(0, 500), metrics }
  } finally {
    await sanitizeRevealSurface(page).catch(() => false)
    await context.close()
  }
}

async function runPersonaB(browser) {
  const context = await browser.newContext({
    serviceWorkers: 'block',
    viewport: { width: 1280, height: 900 },
  })
  const metrics = createMetrics()
  installRouting(context, metrics)
  const page = await context.newPage()
  attachMetrics(page, metrics)
  const suffix = `${Date.now()}_${process.pid}`
  const credentials = {
    username: process.env.PERSONA_USERNAME ?? `preview_buyer_${suffix}`,
    email:
      process.env.PERSONA_EMAIL ?? `preview_buyer_${suffix}@example.invalid`,
    password: process.env.PERSONA_PASSWORD ?? 'PreviewPass123!',
  }
  const tokenName = `acceptance-credential-${suffix}`
  const evidence = {
    registrationSucceeded: false,
    loginSucceeded: false,
    initialSelfValid: false,
    gettingStartedPathUsed: false,
    tokenCreateCount: 0,
    tokenListed: false,
    revealReturnedNonemptyKey: false,
    persistedAfterReload: false,
    refreshedSelfValid: false,
    secondUserIsolationVerified: false,
  }
  let status = 'FAIL'
  let error = ''
  try {
    evidence.registrationSucceeded = await registerThroughUI(page, credentials)
    const initialSelfResponsePromise = waitForApiResponse(
      page,
      'GET',
      '/api/user/self'
    )
    evidence.loginSucceeded =
      evidence.registrationSucceeded &&
      (await loginThroughUI(page, credentials))
    if (!evidence.loginSucceeded) {
      throw new Error('registration or login evidence failed')
    }
    await requireDataResponse(
      await initialSelfResponsePromise,
      (data) =>
        validSelfData(data, { credentialComplete: false, stage: 'credential' }),
      'initial self'
    )
    evidence.initialSelfValid = true
    await page.waitForURL(/\/getting-started(?:\/|$)/, { timeout: 10_000 })
    const createCredential = page.getByRole('link', {
      name: 'Create credential',
      exact: true,
    })
    if ((await createCredential.getAttribute('href')) !== '/keys') {
      throw new Error('getting-started credential link does not target /keys')
    }
    await createCredential.click()
    await page.waitForURL(/\/keys(?:\/|$)/, { timeout: 10_000 })
    evidence.gettingStartedPathUsed = true

    await page
      .getByRole('button', { name: 'Create API Key', exact: true })
      .click()
    await page.getByLabel('Name', { exact: true }).fill(tokenName)
    const createResponsePromise = page.waitForResponse(
      (response) =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/api/token/'
    )
    const createdListResponsePromise = waitForApiResponse(
      page,
      'GET',
      '/api/token/'
    )
    await page
      .getByRole('button', { name: 'Save changes', exact: true })
      .click()
    const createResponse = await createResponsePromise
    evidence.tokenCreateCount = metrics.responses.filter(
      (response) =>
        response.method === 'POST' &&
        response.path === '/api/token/' &&
        response.status < 400
    ).length
    await requireActionResponse(createResponse, 'credential creation')
    if (evidence.tokenCreateCount !== 1) {
      throw new Error(
        'credential creation was not exactly one successful request'
      )
    }
    const createdList = await requireDataResponse(
      await createdListResponsePromise,
      validTokenListData,
      'created credential list'
    )
    const createdMatches = createdList.items.filter(
      (item) => item.name === tokenName
    )
    if (
      createdMatches.length !== 1 ||
      !Number.isInteger(createdMatches[0].id)
    ) {
      throw new Error(
        'created credential is missing, duplicated, or has an invalid ID'
      )
    }
    const createdTokenId = createdMatches[0].id
    await page
      .getByText(tokenName, { exact: true })
      .waitFor({ timeout: 10_000 })
    evidence.tokenListed = true

    const revealResponsePromise = page.waitForResponse(
      (response) =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/token/${createdTokenId}/key`
    )
    const tokenRow = page
      .getByText(tokenName, { exact: true })
      .locator('xpath=ancestor::*[self::tr or @data-slot="table-row"][1]')
    const maskedKey = tokenRow.getByText(/^sk-/).first()
    await maskedKey.click()
    const revealResponse = await revealResponsePromise
    if (revealResponse.status() >= 400) {
      throw new Error('credential reveal HTTP response failed')
    }
    let revealError = null
    try {
      evidence.revealReturnedNonemptyKey = await page.evaluate(() => {
        const tokenPattern = /^sk-[A-Za-z0-9_-]{12,}$/
        const secretInput = [...document.querySelectorAll('input')].find(
          (input) => tokenPattern.test(input.value)
        )
        return Boolean(secretInput)
      })
      if (!evidence.revealReturnedNonemptyKey) {
        throw new Error('credential reveal was empty')
      }
    } catch (caught) {
      revealError = caught
    } finally {
      if (!(await sanitizeRevealSurface(page))) {
        revealError = new Error(
          'credential reveal surface could not be sanitized'
        )
      }
    }
    if (revealError) {
      throw revealError
    }

    await page.goto(new URL('/getting-started', baseUrl).toString(), {
      waitUntil: 'domcontentloaded',
    })
    const refreshResponsePromise = waitForApiResponse(
      page,
      'POST',
      '/api/user/auth/refresh'
    )
    const refreshedSelfResponsePromise = waitForApiResponse(
      page,
      'GET',
      '/api/user/self'
    )
    const persistedListResponsePromise = waitForApiResponse(
      page,
      'GET',
      '/api/token/'
    )
    await page.reload({ waitUntil: 'domcontentloaded' })
    await requireDataResponse(
      await refreshResponsePromise,
      validAuthBundle,
      'bootstrap refresh'
    )
    await page.waitForURL(/\/getting-started(?:\/|$)/, { timeout: 10_000 })
    await requireDataResponse(
      await refreshedSelfResponsePromise,
      (data) =>
        validSelfData(data, {
          credentialComplete: true,
          stage: 'first_request',
        }),
      'refreshed self'
    )
    evidence.refreshedSelfValid = true
    await page.goto(new URL('/keys', baseUrl).toString(), {
      waitUntil: 'domcontentloaded',
    })
    const persistedList = await requireDataResponse(
      await persistedListResponsePromise,
      validTokenListData,
      'persisted credential list'
    )
    evidence.persistedAfterReload = persistedList.items.some(
      (item) => item.name === tokenName
    )
    if (!evidence.persistedAfterReload) {
      throw new Error('credential did not persist after bootstrap reload')
    }

    const isolation = await runSecondUserIsolation(browser, tokenName, suffix)
    evidence.secondUserIsolationVerified = isolation.verified
    evidence.secondUserIsolation = {
      verified: isolation.verified,
      observedFirstCredential: isolation.observedFirstCredential === true,
      reason: isolation.reason || '',
    }
    if (!isolation.verified) {
      throw new Error('second-user credential isolation was not verified')
    }
    const allMetrics = [metrics, isolation.metrics]
    const unsafeTraffic = {
      blockedExternal: allMetrics.flatMap((item) => item.blockedExternal),
      blockedMutations: allMetrics.flatMap((item) => item.blockedMutations),
      unexpectedMutations: unexpectedMutationEvidence(allMetrics),
    }
    evidence.combinedSafety = unsafeTraffic
    if (
      unsafeTraffic.blockedExternal.length > 0 ||
      unsafeTraffic.blockedMutations.length > 0 ||
      unsafeTraffic.unexpectedMutations.length > 0
    ) {
      throw new Error('blocked external or forbidden mutation traffic occurred')
    }
    status = 'PASS'
  } catch (caught) {
    error = String(caught).slice(0, 500)
    status = page.url() === 'about:blank' ? 'NEEDS_RUNTIME' : 'FAIL'
  } finally {
    const screenshot = await safeScreenshot(page, 'buyer-final').catch(() => ({
      written: false,
      reason: 'secret sanitization or screenshot failed',
    }))
    evidence.finalScreenshot = screenshot
    if (!screenshot.written && status === 'PASS') status = 'FAIL'
    await context.close()
  }
  return { status, evidence, error, metrics }
}

const browser = await chromium.launch({ headless: true })
const personaA = await runPersonaA(browser)
const personaB = await runPersonaB(browser)
await browser.close()

let status = 'FAIL'
if (personaA.status === 'PASS' && personaB.status === 'PASS') {
  status = 'PASS'
} else if (
  personaA.status === 'NEEDS_RUNTIME' ||
  personaB.status === 'NEEDS_RUNTIME'
) {
  status = 'NEEDS_RUNTIME'
}
const summary = { runId, baseUrl, outputDirectory, personaA, personaB, status }
await writeFile(reportPath, `${JSON.stringify(summary, null, 2)}\n`, {
  flag: 'wx',
})
console.log(
  JSON.stringify(
    {
      status,
      reportPath,
      personaA: {
        status: personaA.status,
        jargonFindings: personaA.jargonFindings,
        intendedCtas: personaA.intendedCtas,
      },
      personaB: {
        status: personaB.status,
        evidence: personaB.evidence,
        error: personaB.error,
      },
    },
    null,
    2
  )
)
