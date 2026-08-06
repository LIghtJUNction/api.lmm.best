const LOOPBACK_HOSTNAMES = new Set(['localhost', '127.0.0.1', '::1'])

export function isLocalPreview() {
  if (import.meta.env.VITE_LOCAL_PREVIEW !== 'true') return false
  if (typeof window === 'undefined') return false

  return LOOPBACK_HOSTNAMES.has(window.location.hostname)
}
