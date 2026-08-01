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
import {
  PAYMENT_TYPES,
  DEFAULT_PRESET_MULTIPLIERS,
  DEFAULT_PAYMENT_TYPE,
  DEFAULT_MIN_TOPUP,
} from '../constants'
import type { PaymentMethod, PresetAmount, TopupInfo } from '../types'
import { getPaymentCurrencyLabel } from './format'

// ============================================================================
// Payment Processing Functions
// ============================================================================

/**
 * Check if browser is Safari
 */
function isSafariBrowser(): boolean {
  return (
    navigator.userAgent.includes('Safari') &&
    !navigator.userAgent.includes('Chrome')
  )
}

/**
 * Submit payment form (for non-Stripe payments)
 */
export function submitPaymentForm(
  url: string,
  params: Record<string, unknown>,
  target?: string | null
): boolean {
  if (!isSafeHttpCheckoutUrl(url)) {
    return false
  }

  const form = document.createElement('form')
  form.action = url
  form.method = 'POST'

  if (target) {
    form.target = target
  } else if (target === undefined && !isSafariBrowser()) {
    // Preserve the legacy behavior for callers that do not reserve a window.
    form.target = '_blank'
  }

  // Add form parameters
  Object.entries(params).forEach(([key, value]) => {
    const input = document.createElement('input')
    input.type = 'hidden'
    input.name = key
    input.value = String(value)
    form.appendChild(input)
  })

  document.body.appendChild(form)
  form.submit()
  document.body.removeChild(form)
  return true
}

/** Reject relative and non-http(s) redirect targets returned by a gateway. */
export function isSafeHttpCheckoutUrl(value: unknown): value is string {
  if (typeof value !== 'string' || !value.trim()) {
    return false
  }

  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

export type PaymentCheckout = {
  /** A reserved popup target, or null when the safe fallback is same-tab. */
  target: string | null
  popup: Window | null
}

/**
 * Reserve a popup while the click is still a user gesture. Gateway responses
 * arrive asynchronously, so opening a new window after awaiting them is
 * routinely blocked by browsers. Safari keeps the legacy same-tab flow.
 */
export function reservePaymentCheckout(): PaymentCheckout {
  if (isSafariBrowser()) {
    return { target: null, popup: null }
  }

  const target = `payment_checkout_${Date.now()}_${Math.random()
    .toString(36)
    .slice(2)}`
  const popup = window.open('about:blank', target, 'noopener,noreferrer')

  // Defense in depth for browsers that return a Window despite the features.
  // The checkout must never receive a reference to the application window.
  if (popup) {
    try {
      popup.opener = null
    } catch {
      // Cross-origin browser implementations may expose a read-only opener.
    }
  }

  return popup ? { target, popup } : { target: null, popup: null }
}

/** Close an unused reserved popup after a failed payment request. */
export function cancelPaymentCheckout(checkout: PaymentCheckout): void {
  checkout.popup?.close()
}

/**
 * Navigate a reserved checkout window. If the browser declined the popup,
 * fall back to a safe same-tab navigation rather than trying another blocked
 * popup after the async request completes.
 */
export function redirectToPaymentCheckout(
  checkout: PaymentCheckout,
  url: unknown
): boolean {
  if (!isSafeHttpCheckoutUrl(url)) {
    return false
  }

  if (checkout.popup && !checkout.popup.closed) {
    checkout.popup.location.href = url
    checkout.popup.focus()
  } else {
    window.location.href = url
  }

  return true
}

/**
 * Check if payment method is Stripe
 */
export function isStripePayment(paymentType: string): boolean {
  return paymentType === PAYMENT_TYPES.STRIPE
}

/**
 * Check if payment method is Waffo
 */
export function isWaffoPayment(paymentType: string): boolean {
  return paymentType === PAYMENT_TYPES.WAFFO
}

/**
 * Check if payment method is Waffo Pancake
 *
 * Pancake is a metered-style payment that goes through a dedicated checkout
 * URL flow rather than the generic epay form submission, so it must be
 * special-cased in payment dispatch logic.
 */
export function isWaffoPancakePayment(paymentType: string): boolean {
  return paymentType === PAYMENT_TYPES.WAFFO_PANCAKE
}

/**
 * The frozen Go Waffo Pancake checkout always creates USD orders. Do not let
 * a CNY-configured page label that USD order as CNY or send it to checkout.
 */
export function isWaffoPancakeCurrencySupported(): boolean {
  return getPaymentCurrencyLabel() === 'USD'
}

/** Provider-specific currency policy; other gateway providers retain CNY. */
export function isPaymentMethodCurrencySupported(paymentType: string): boolean {
  return (
    !isWaffoPancakePayment(paymentType) || isWaffoPancakeCurrencySupported()
  )
}

export interface PaymentProcessors {
  regular: (topupAmount: number, paymentType: string) => Promise<boolean>
  waffo: (topupAmount: number, payMethodIndex: number) => Promise<boolean>
  waffoPancake: (topupAmount: number) => Promise<boolean>
}

export async function dispatchSelectedPayment(
  paymentMethod: PaymentMethod,
  topupAmount: number,
  waffoMethodIndex: number | null,
  processors: PaymentProcessors
): Promise<boolean> {
  if (isWaffoPayment(paymentMethod.type)) {
    if (waffoMethodIndex === null) {
      return false
    }
    return processors.waffo(topupAmount, waffoMethodIndex)
  }

  if (isWaffoPancakePayment(paymentMethod.type)) {
    return processors.waffoPancake(topupAmount)
  }

  return processors.regular(topupAmount, paymentMethod.type)
}

/**
 * Get default payment type from topup info
 */
export function getDefaultPaymentType(topupInfo: TopupInfo | null): string {
  if (!topupInfo) {
    return DEFAULT_PAYMENT_TYPE
  }

  // Return first available payment method or default
  if (topupInfo.pay_methods?.length > 0) {
    return topupInfo.pay_methods[0].type
  }

  if (topupInfo.enable_stripe_topup) {
    return PAYMENT_TYPES.STRIPE
  }

  if (topupInfo.enable_waffo_topup) {
    return PAYMENT_TYPES.WAFFO
  }

  if (topupInfo.enable_waffo_pancake_topup) {
    return PAYMENT_TYPES.WAFFO_PANCAKE
  }

  return DEFAULT_PAYMENT_TYPE
}

/**
 * Get minimum topup amount from topup info
 */
export function getMinTopupAmount(topupInfo: TopupInfo | null): number {
  if (!topupInfo) {
    return DEFAULT_MIN_TOPUP
  }

  if (topupInfo.enable_online_topup) {
    return topupInfo.min_topup
  }

  if (topupInfo.enable_stripe_topup) {
    return topupInfo.stripe_min_topup
  }

  if (topupInfo.enable_waffo_topup) {
    return topupInfo.waffo_min_topup || DEFAULT_MIN_TOPUP
  }

  if (topupInfo.enable_waffo_pancake_topup) {
    return topupInfo.waffo_pancake_min_topup || DEFAULT_MIN_TOPUP
  }

  return DEFAULT_MIN_TOPUP
}

/**
 * Generate preset amounts based on minimum topup
 */
export function generatePresetAmounts(minAmount: number): PresetAmount[] {
  return DEFAULT_PRESET_MULTIPLIERS.map((multiplier) => ({
    value: minAmount * multiplier,
  }))
}

/**
 * Merge custom preset amounts with discounts
 */
export function mergePresetAmounts(
  amountOptions: number[],
  discounts: Record<number, number>
): PresetAmount[] {
  if (!amountOptions || amountOptions.length === 0) {
    return []
  }

  return amountOptions.map((amount) => ({
    value: amount,
    discount: discounts[amount] || 1.0,
  }))
}
