/**
 * Haptic feedback helpers.
 *
 * Thin, safe wrappers around `navigator.vibrate` that no-op gracefully on
 * environments where the API is unavailable (desktop, older browsers, iOS
 * Safari which ignores vibration, etc.).
 */

function vibrate(pattern: number[]): void {
  if (typeof navigator === 'undefined') return
  if (typeof navigator.vibrate !== 'function') return
  navigator.vibrate(pattern)
}

/** Short click feedback for taps, chips and tab switches. */
export function hapticLight(): void {
  vibrate([15])
}

/** Longer confirmation buzz for completed loads (e.g. a batch of data). */
export function hapticSuccess(): void {
  vibrate([30, 50, 30])
}
