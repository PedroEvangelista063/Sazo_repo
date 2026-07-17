'use client'

import { useState } from 'react'
import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'

const FRUIT_EMOJIS = ['🍎', '🍌', '🍅', '🍊', '🍇']

interface BRNationalIconProps {
  onClick: () => void
  isActive: boolean
}

export function BRNationalIcon({ onClick, isActive }: BRNationalIconProps) {
  const [hovered, setHovered] = useState(false)

  return (
    <motion.button
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      whileTap={{ scale: 0.92 }}
      aria-label="Selecionar BR Nacional — Grade Sazonal"
      className={cn(
        'relative flex items-center justify-center rounded-full border-2 shadow-md transition-shadow duration-300',
        'min-h-[44px] min-w-[44px] h-11 w-11',
        isActive || hovered
          ? 'border-green-500 shadow-green-500/30'
          : 'border-gray-300 dark:border-gray-600',
      )}
      style={{
        background: isActive || hovered
          ? 'linear-gradient(135deg, #009739 0%, #FEDD00 50%, #009739 100%)'
          : undefined,
      }}
    >
      {/* Partículas de fruta orbitando */}
      {FRUIT_EMOJIS.map((emoji, i) => {
        const orbitDuration = 8 + i * 2
        const delay = i * 1.2
        const size = hovered ? 14 : 11
        return (
          <span
            key={emoji}
            className="pointer-events-none absolute select-none transition-all duration-300"
            style={{
              animation: `fruit-orbit-${i} ${orbitDuration}s linear infinite`,
              animationDelay: `${delay}s`,
              fontSize: `${size}px`,
              opacity: hovered ? 1 : 0.6,
              width: 0,
              height: 0,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            {emoji}
          </span>
        )
      })}

      {/* Ícone central com pulse */}
      <motion.span
        className="relative z-10 text-lg leading-none"
        animate={{
          scale: hovered ? [1, 1.15, 1] : [1, 1.05, 1],
        }}
        transition={{
          duration: hovered ? 1.5 : 3,
          repeat: Infinity,
          ease: 'easeInOut',
        }}
      >
        🇧🇷
      </motion.span>
    </motion.button>
  )
}
