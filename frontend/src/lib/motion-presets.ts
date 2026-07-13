import { Variants, TargetAndTransition } from 'framer-motion'

export const gameButtonVariants: Variants = {
  idle: { scale: 1, filter: 'brightness(1)' },
  hover: {
    scale: 1.03,
    filter: 'brightness(1.15)',
    transition: { type: 'spring', stiffness: 400, damping: 17 },
  },
  tap: {
    scale: 0.96,
    filter: 'brightness(0.95)',
    transition: { duration: 0.05 },
  },
}

export const shakeX = (x = 8): TargetAndTransition => ({
  x: [0, -x, x, -x / 2, x / 2, 0],
  transition: { duration: 0.35, ease: 'easeOut' },
})

export const glowPulse = (color = '#16a34a'): TargetAndTransition => ({
  boxShadow: [
    `0 0 0 0 ${color}00`,
    `0 0 16px 6px ${color}60`,
    `0 0 0 0 ${color}00`,
  ],
  transition: { duration: 2, repeat: Infinity, ease: 'easeInOut' },
})

export const staggerContainer: Variants = {
  hidden: { opacity: 0 },
  visible: {
    opacity: 1,
    transition: { staggerChildren: 0.03, delayChildren: 0.1 },
  },
}

export const staggerItem: Variants = {
  hidden: { opacity: 0, y: 20, scale: 0.95 },
  visible: {
    opacity: 1,
    y: 0,
    scale: 1,
    transition: { type: 'spring', stiffness: 400, damping: 25 },
  },
}

export const slideUpFade: Variants = {
  hidden: { opacity: 0, y: 20 },
  visible: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.3, ease: [0.25, 0.46, 0.45, 0.94] },
  },
  exit: {
    opacity: 0,
    y: -20,
    transition: { duration: 0.2, ease: [0.55, 0.055, 0.675, 0.19] },
  },
}

export const scaleSpring: Variants = {
  hidden: { scale: 0.8, opacity: 0 },
  visible: {
    scale: 1,
    opacity: 1,
    transition: { type: 'spring', stiffness: 500, damping: 25 },
  },
}

export const pulseGlow = (color = '#16a34a', intensity = 1): TargetAndTransition => ({
  boxShadow: [
    `0 0 0 0 ${color}00`,
    `0 0 ${12 * intensity}px ${4 * intensity}px ${color}60`,
    `0 0 0 0 ${color}00`,
  ],
  transition: { duration: 2, repeat: Infinity, ease: 'easeInOut' },
})

export const shimmer = (): TargetAndTransition => ({
  backgroundPosition: ['200% 0', '-200% 0', '200% 0'],
  transition: { duration: 1.5, repeat: Infinity, ease: 'linear' },
})