import { useEffect, useState } from 'react'

/**
 * Minimal typing for the non-standard `beforeinstallprompt` event.
 * Not part of the standard TS DOM lib — declared locally per spec.
 */
interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

/** localStorage keys used to avoid re-showing the banner after install/dismissal. */
export const PWA_STORAGE_KEYS = {
  dismissed: 'pwa_install_dismissed',
  installed: 'pwa_installed',
} as const

export interface PWAInstallState {
  /** True when the banner should be offered on this device. */
  canInstall: boolean
  /** True when running Safari on iOS (A2HS instructions apply). */
  isIOS: boolean
  /** True when the app is already running in standalone (installed) mode. */
  isStandalone: boolean
  /** Prompts the native install flow (Android/Chromium only). */
  install: () => Promise<void>
  /** Dismisses the banner and persists the dismissal. */
  dismiss: () => void
  /** True once the user confirmed the native install prompt. */
  installed: boolean
  /** True when the user already installed or dismissed the banner. */
  hasInteracted: boolean
}

function readStorage(key: string): string | null {
  try {
    return window.localStorage.getItem(key)
  } catch {
    // Storage unavailable (private mode, blocked) — treat as never set.
    return null
  }
}

function writeStorage(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // Storage unavailable — non-blocking.
  }
}

/**
 * iOS Safari detection. iPadOS 13+ reports a Macintosh UA, so we also check
 * `navigator.platform === 'MacIntel'` combined with touch points, and exclude
 * Chrome/Firefox/Edge/Opera iOS wrappers (CriOS/FxiOS/EdgiOS/OPiOS).
 */
function isIOSDevice(): boolean {
  if (typeof navigator === 'undefined') return false
  const ua = navigator.userAgent
  const isApplePortable = /iP(hone|ad|od)/.test(ua)
  const isIpadMacIntel = navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1
  if (!isApplePortable && !isIpadMacIntel) return false
  const isSafari = /Safari/.test(ua)
  const isWrapperBrowser = /CriOS|FxiOS|EdgiOS|OPiOS/.test(ua)
  return isSafari && !isWrapperBrowser
}

/**
 * A2HS (Add to Home Screen) install hook.
 *
 * - Android/Chromium: intercepts `beforeinstallprompt`, calls `preventDefault()`
 *   so the native prompt never appears on its own, and stores the event so the
 *   UI can trigger it explicitly via `install()`.
 * - iOS Safari: no prompt event exists; `isIOS` is exposed so the UI can show
 *   "Como Instalar?" instructions instead.
 * - Standalone mode (display-mode: standalone) is respected: once the app runs
 *   installed, no banner is offered (also covers iOS after A2HS).
 */
export function usePWAInstall(): PWAInstallState {
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(null)
  const [isStandalone, setIsStandalone] = useState(false)
  const [dismissed, setDismissed] = useState(() => readStorage(PWA_STORAGE_KEYS.dismissed) === '1')
  const [installed, setInstalled] = useState(() => readStorage(PWA_STORAGE_KEYS.installed) === '1')

  const isIOS = isIOSDevice()

  useEffect(() => {
    const media = window.matchMedia('(display-mode: standalone)')
    setIsStandalone(media.matches)
    const handleChange = (e: MediaQueryListEvent) => setIsStandalone(e.matches)
    media.addEventListener('change', handleChange)
    return () => media.removeEventListener('change', handleChange)
  }, [])

  useEffect(() => {
    const handleBeforeInstallPrompt = (e: Event) => {
      // The native prompt must NOT appear on its own — intercept it.
      e.preventDefault()
      setDeferredPrompt(e as BeforeInstallPromptEvent)
    }
    window.addEventListener('beforeinstallprompt', handleBeforeInstallPrompt)
    return () => window.removeEventListener('beforeinstallprompt', handleBeforeInstallPrompt)
  }, [])

  const install = async (): Promise<void> => {
    if (isIOS || !deferredPrompt) return
    await deferredPrompt.prompt()
    const choice = await deferredPrompt.userChoice
    if (choice.outcome === 'accepted') {
      setInstalled(true)
      writeStorage(PWA_STORAGE_KEYS.installed, '1')
    } else {
      setDismissed(true)
      writeStorage(PWA_STORAGE_KEYS.dismissed, '1')
    }
    setDeferredPrompt(null)
  }

  const dismiss = (): void => {
    setDismissed(true)
    writeStorage(PWA_STORAGE_KEYS.dismissed, '1')
  }

  const canInstall = !isStandalone && !dismissed && !installed && (deferredPrompt !== null || isIOS)

  return {
    canInstall,
    isIOS,
    isStandalone,
    install,
    dismiss,
    installed,
    hasInteracted: dismissed || installed,
  }
}
