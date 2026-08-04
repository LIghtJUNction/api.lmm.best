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
import { describe, test } from 'node:test'

import { useSystemConfigStore } from '@/stores/system-config-store'

import { PAYMENT_TYPES } from '../constants'
import {
  cancelPaymentCheckout,
  dispatchSelectedPayment,
  getEpayMethods,
  isSafeHttpCheckoutUrl,
  isPaymentMethodCurrencySupported,
  isStripePayment,
  isWaffoPayment,
  isWaffoPancakePayment,
  redirectToPaymentCheckout,
  reservePaymentCheckout,
  submitPaymentForm,
} from './payment'

describe('payment type classification', () => {
  test('keeps Waffo and Waffo Pancake on their dedicated flows', () => {
    assert.equal(isWaffoPayment(PAYMENT_TYPES.WAFFO), true)
    assert.equal(isWaffoPayment(PAYMENT_TYPES.WAFFO_PANCAKE), false)
    assert.equal(isWaffoPancakePayment(PAYMENT_TYPES.WAFFO_PANCAKE), true)
    assert.equal(isWaffoPancakePayment(PAYMENT_TYPES.WAFFO), false)
    assert.equal(isStripePayment(PAYMENT_TYPES.STRIPE), true)
  })

  test('keeps only generic ePay methods and excludes dedicated gateways', () => {
    const epayMethods = getEpayMethods([
      { name: 'Alipay', type: 'alipay' },
      { name: 'WeChat Pay', type: 'wxpay' },
      { name: 'Stripe', type: PAYMENT_TYPES.STRIPE },
      { name: 'Creem', type: PAYMENT_TYPES.CREEM },
      { name: 'Waffo', type: PAYMENT_TYPES.WAFFO },
      { name: 'Waffo Pancake', type: PAYMENT_TYPES.WAFFO_PANCAKE },
    ])

    assert.deepEqual(
      epayMethods.map((method) => method.type),
      ['alipay', 'wxpay']
    )
  })

  test('treats missing or empty payment method lists as no ePay methods', () => {
    assert.deepEqual(getEpayMethods(), [])
    assert.deepEqual(getEpayMethods([]), [])
  })

  test('fails closed only for Waffo Pancake when the configured gateway currency is CNY', () => {
    const originalConfig = useSystemConfigStore.getState().config
    try {
      useSystemConfigStore.setState((state) => ({
        config: {
          ...state.config,
          currency: { ...state.config.currency, quotaDisplayType: 'CNY' },
        },
      }))
      assert.equal(
        isPaymentMethodCurrencySupported(PAYMENT_TYPES.WAFFO_PANCAKE),
        false
      )
      assert.equal(isPaymentMethodCurrencySupported('alipay'), true)

      useSystemConfigStore.setState((state) => ({
        config: {
          ...state.config,
          currency: { ...state.config.currency, quotaDisplayType: 'USD' },
        },
      }))
      assert.equal(
        isPaymentMethodCurrencySupported(PAYMENT_TYPES.WAFFO_PANCAKE),
        true
      )
    } finally {
      useSystemConfigStore.setState((state) => ({
        ...state,
        config: originalConfig,
      }))
    }
  })
})

describe('payment dispatch', () => {
  test('keeps the selected Waffo method index through confirmation', async () => {
    const calls: string[] = []
    const success = await dispatchSelectedPayment(
      { name: 'Waffo Card', type: PAYMENT_TYPES.WAFFO },
      120,
      3,
      {
        regular: async () => {
          calls.push('regular')
          return false
        },
        waffo: async (amount, index) => {
          calls.push(`waffo:${amount}:${index}`)
          return true
        },
        waffoPancake: async () => {
          calls.push('pancake')
          return false
        },
      }
    )

    assert.equal(success, true)
    assert.deepEqual(calls, ['waffo:120:3'])
  })

  test('does not create a Waffo order without a selected method index', async () => {
    let called = false
    const success = await dispatchSelectedPayment(
      { name: 'Waffo Card', type: PAYMENT_TYPES.WAFFO },
      120,
      null,
      {
        regular: async () => false,
        waffo: async () => {
          called = true
          return true
        },
        waffoPancake: async () => false,
      }
    )

    assert.equal(success, false)
    assert.equal(called, false)
  })
})

describe('payment checkout navigation', () => {
  test('only accepts absolute HTTP(S) redirect URLs', () => {
    assert.equal(
      isSafeHttpCheckoutUrl('https://pay.example.test/checkout'),
      true
    )
    assert.equal(isSafeHttpCheckoutUrl('http://localhost:3000/checkout'), true)
    assert.equal(isSafeHttpCheckoutUrl('/checkout'), false)
    assert.equal(isSafeHttpCheckoutUrl('javascript:alert(1)'), false)
    assert.equal(isSafeHttpCheckoutUrl('data:text/html,payment'), false)
    assert.equal(isSafeHttpCheckoutUrl(''), false)
  })

  test('reserves a click-time popup then sends both CNY and USD form posts to it', () => {
    const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
    const originalNavigator = Object.getOwnPropertyDescriptor(
      globalThis,
      'navigator'
    )
    const originalDocument = Object.getOwnPropertyDescriptor(
      globalThis,
      'document'
    )
    const submitted: Array<{
      action: string
      method: string
      target: string
      fields: Array<[string, string]>
    }> = []
    const popup = {
      closed: false,
      opener: {} as Window | null,
      close: () => undefined,
      focus: () => undefined,
      location: { href: '' },
    }

    try {
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: { userAgent: 'Mozilla/5.0 Chrome/140.0' },
      })
      Object.defineProperty(globalThis, 'window', {
        configurable: true,
        value: {
          location: { href: '' },
          open: (url: string, target: string, features: string) => {
            assert.equal(url, 'about:blank')
            assert.match(target, /^payment_checkout_/)
            assert.equal(features, 'noopener,noreferrer')
            return popup
          },
        },
      })
      Object.defineProperty(globalThis, 'document', {
        configurable: true,
        value: {
          body: {
            appendChild: () => undefined,
            removeChild: () => undefined,
          },
          createElement: (tag: string) => {
            if (tag === 'form') {
              const fields: Array<[string, string]> = []
              return {
                action: '',
                method: '',
                target: '',
                appendChild: (input: { name: string; value: string }) => {
                  fields.push([input.name, input.value])
                },
                submit(this: {
                  action: string
                  method: string
                  target: string
                }) {
                  submitted.push({
                    action: this.action,
                    method: this.method,
                    target: this.target,
                    fields,
                  })
                },
              }
            }
            return { name: '', value: '', type: '' }
          },
        },
      })

      const checkout = reservePaymentCheckout()
      assert.ok(checkout.target)
      assert.equal(popup.opener, null)
      assert.equal(
        submitPaymentForm(
          'https://pay.example.test/submit',
          { amount: '10.00', currency: 'CNY' },
          checkout.target
        ),
        true
      )
      assert.equal(
        submitPaymentForm(
          'https://pay.example.test/submit',
          { amount: '12.50', currency: 'USD' },
          checkout.target
        ),
        true
      )
      assert.deepEqual(submitted, [
        {
          action: 'https://pay.example.test/submit',
          method: 'POST',
          target: checkout.target,
          fields: [
            ['amount', '10.00'],
            ['currency', 'CNY'],
          ],
        },
        {
          action: 'https://pay.example.test/submit',
          method: 'POST',
          target: checkout.target,
          fields: [
            ['amount', '12.50'],
            ['currency', 'USD'],
          ],
        },
      ])
      assert.equal(
        submitPaymentForm('javascript:alert(1)', {}, checkout.target),
        false
      )

      assert.equal(
        redirectToPaymentCheckout(checkout, 'https://pay.example.test/hosted'),
        true
      )
      assert.equal(popup.location.href, 'https://pay.example.test/hosted')
      cancelPaymentCheckout(checkout)
    } finally {
      if (originalWindow) {
        Object.defineProperty(globalThis, 'window', originalWindow)
      } else {
        Reflect.deleteProperty(globalThis, 'window')
      }
      if (originalNavigator) {
        Object.defineProperty(globalThis, 'navigator', originalNavigator)
      } else {
        Reflect.deleteProperty(globalThis, 'navigator')
      }
      if (originalDocument) {
        Object.defineProperty(globalThis, 'document', originalDocument)
      } else {
        Reflect.deleteProperty(globalThis, 'document')
      }
    }
  })

  test('uses same-tab navigation when a popup is blocked or closes before redirect', () => {
    const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
    const originalNavigator = Object.getOwnPropertyDescriptor(
      globalThis,
      'navigator'
    )
    const location = { href: '' }

    try {
      Object.defineProperty(globalThis, 'navigator', {
        configurable: true,
        value: { userAgent: 'Mozilla/5.0 Chrome/140.0' },
      })
      Object.defineProperty(globalThis, 'window', {
        configurable: true,
        value: {
          location,
          open: () => null,
        },
      })

      const blockedCheckout = reservePaymentCheckout()
      assert.equal(blockedCheckout.target, null)
      assert.equal(
        redirectToPaymentCheckout(
          blockedCheckout,
          'https://pay.example.test/blocked'
        ),
        true
      )
      assert.equal(location.href, 'https://pay.example.test/blocked')

      const closedCheckout = {
        target: 'payment_checkout_closed',
        popup: {
          closed: true,
          focus: () => undefined,
          location: { href: '' },
        } as unknown as Window,
      }
      assert.equal(
        redirectToPaymentCheckout(
          closedCheckout,
          'https://pay.example.test/closed'
        ),
        true
      )
      assert.equal(location.href, 'https://pay.example.test/closed')
    } finally {
      if (originalWindow) {
        Object.defineProperty(globalThis, 'window', originalWindow)
      } else {
        Reflect.deleteProperty(globalThis, 'window')
      }
      if (originalNavigator) {
        Object.defineProperty(globalThis, 'navigator', originalNavigator)
      } else {
        Reflect.deleteProperty(globalThis, 'navigator')
      }
    }
  })
})
