import { useCallback } from 'react'
import confetti from 'canvas-confetti'

const DEFAULT_COLORS = ['#16a34a', '#22c55e', '#4ade80', '#ffffff', '#86efac']

let reducedMotion = false
if (typeof window !== 'undefined') {
  reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

export function useConfetti() {
  const fire = useCallback(
    (options: confetti.Options = {}) => {
      if (reducedMotion) return

      const opts: confetti.Options = {
        particleCount: 60,
        spread: 70,
        origin: { y: 0.6 },
        colors: DEFAULT_COLORS,
        zIndex: 9999,
        scalar: 1,
        shapes: ['circle', 'square'],
        gravity: 1,
        drift: 0,
        ...options,
      }

      confetti(opts)
    },
    []
  )

  const fireSuccess = useCallback(
    (origin?: { x: number; y: number }) => {
      fire({
        particleCount: 80,
        spread: 80,
        origin: origin ?? { y: 0.5 },
        colors: ['#16a34a', '#22c55e', '#4ade80', '#ffffff', '#86efac'],
        scalar: 1.2,
        shapes: ['circle', 'square', 'star'],
      })
    },
    [fire]
  )

  const fireCelebration = useCallback(
    (origin?: { x: number; y: number }) => {
      fire({
        particleCount: 120,
        spread: 100,
        origin: origin ?? { y: 0.5 },
        colors: ['#16a34a', '#3b82f6', '#f59e0b', '#ec4899', '#ffffff', '#86efac'],
        scalar: 1.5,
        shapes: ['circle', 'square', 'star'],
        gravity: 0.8,
      })
    },
    [fire]
  )

  const fireBurst = useCallback(
    (x: number, y: number, color = '#16a34a') => {
      if (reducedMotion) return
      confetti({
        particleCount: 30,
        spread: 60,
        origin: { x, y },
        colors: [color, '#ffffff'],
        scalar: 1,
        shapes: ['circle'],
      })
    },
    []
  )

  const fireLine = useCallback(
    (fromX: number, fromY: number, toX: number, toY: number, color = '#16a34a') => {
      if (reducedMotion) return
      const steps = 5
      for (let i = 0; i <= steps; i++) {
        const t = i / steps
        const x = fromX + (toX - fromX) * t
        const y = fromY + (toY - fromY) * t
        setTimeout(() => {
          confetti({
            particleCount: 10,
            spread: 30,
            origin: { x, y },
            colors: [color, '#ffffff'],
            scalar: 0.8,
            shapes: ['circle'],
          })
        }, i * 30)
      }
    },
    []
  )

  return {
    fire,
    fireSuccess,
    fireCelebration,
    fireBurst,
    fireLine,
  }
}