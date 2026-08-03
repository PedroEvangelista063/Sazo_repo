import { motion } from 'framer-motion'
import { gameButtonVariants } from '@/lib/motion-presets'
import { cn } from '@/lib/utils'

interface GameButtonProps {
  variant?: 'primary' | 'secondary' | 'danger' | 'ghost' | 'success'
  size?: 'sm' | 'md' | 'lg' | 'icon'
  loading?: boolean
  error?: boolean
  children: React.ReactNode
  icon?: React.ReactNode
  iconPosition?: 'left' | 'right'
  fullWidth?: boolean
  pulse?: boolean
  className?: string
  disabled?: boolean
  onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void
  type?: 'button' | 'submit' | 'reset'
}

const VARIANT_STYLES: Record<string, string> = {
  primary: `
    bg-sazonal-verde-600 text-white
    shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_3px_0_rgb(5,100,48)]
    hover:shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_5px_0_rgb(5,100,48)]
    active:shadow-[inset_0_-2px_0_rgba(0,0,0,0.22),0_1px_0_rgb(5,100,48)]
  `,
  secondary: `
    bg-sazonal-amarelo-600 text-white
    shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_3px_0_rgb(161,98,7)]
    hover:shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_5px_0_rgb(161,98,7)]
    active:shadow-[inset_0_-2px_0_rgba(0,0,0,0.22),0_1px_0_rgb(161,98,7)]
  `,
  danger: `
    bg-sazonal-vermelho-600 text-white
    shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_3px_0_rgb(185,28,28)]
    hover:shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_5px_0_rgb(185,28,28)]
    active:shadow-[inset_0_-2px_0_rgba(0,0,0,0.22),0_1px_0_rgb(185,28,28)]
  `,
  ghost: `
    bg-transparent text-sazonal-verde-600 dark:text-sazonal-verde-400
    hover:bg-sazonal-verde-50 dark:hover:bg-sazonal-verde-dark/20
    shadow-none
  `,
  success: `
    bg-emerald-600 text-white
    shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_3px_0_rgb(5,122,85)]
    hover:shadow-[inset_0_-3px_0_rgba(0,0,0,0.18),0_5px_0_rgb(5,122,85)]
    active:shadow-[inset_0_-2px_0_rgba(0,0,0,0.22),0_1px_0_rgb(5,122,85)]
  `,
}

const SIZE_STYLES: Record<string, string> = {
  sm: 'px-3 py-1.5 text-xs',
  md: 'px-5 py-2.5 text-sm',
  lg: 'px-7 py-3.5 text-base',
  icon: 'p-2.5',
}

export function GameButton({
  variant = 'primary',
  size = 'md',
  loading = false,
  error = false,
  children,
  icon,
  iconPosition = 'left',
  fullWidth = false,
  pulse = false,
  className = '',
  disabled,
  onClick,
  type = 'button',
}: GameButtonProps) {
  const isDisabled = disabled || loading

  return (
    <motion.button
      variants={gameButtonVariants}
      initial="idle"
      whileHover={isDisabled ? undefined : 'hover'}
      whileTap={isDisabled ? undefined : 'tap'}
      animate={error ? 'shake' : pulse ? 'pulse' : 'idle'}
      disabled={isDisabled}
      onClick={onClick}
      type={type}
      className={cn(
        'relative inline-flex items-center justify-center rounded-2xl font-semibold',
        'transition-shadow',
        variant !== 'ghost' &&
          'bg-[linear-gradient(180deg,rgba(255,255,255,0.18),rgba(255,255,255,0)_45%)]',
        'disabled:cursor-not-allowed disabled:opacity-50',
        VARIANT_STYLES[variant],
        SIZE_STYLES[size],
        fullWidth && 'w-full',
        className,
      )}
    >
      {/* Inner glow pulse when pulse prop is set */}
      {pulse && (
        <motion.span
          className="absolute inset-0 rounded-xl bg-white/15 opacity-0 blur-xl"
          animate={{ opacity: [0, 1, 0] }}
          transition={{ duration: 2, repeat: Infinity, ease: 'easeInOut' }}
        />
      )}

      {/* Loading spinner */}
      {loading && (
        <motion.svg
          className="absolute h-5 w-5 animate-spin text-current"
          viewBox="0 0 24 24"
          initial={{ opacity: 0, scale: 0.5 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ duration: 0.2 }}
        >
          <circle
            cx="12"
            cy="12"
            r="10"
            stroke="currentColor"
            strokeWidth="3"
            fill="none"
            strokeDasharray="31.4 31.4"
            strokeLinecap="round"
          >
            <animateTransform
              attributeName="transform"
              type="rotate"
              from="0 12 12"
              to="360 12 12"
              dur="1s"
              repeatCount="indefinite"
            />
          </circle>
        </motion.svg>
      )}

      {/* Content */}
      <span className={cn('relative z-10 flex items-center gap-2', loading && 'opacity-0')}>
        {icon && iconPosition === 'left' && <span className="flex-shrink-0">{icon}</span>}
        <span className="whitespace-nowrap">{children}</span>
        {icon && iconPosition === 'right' && <span className="flex-shrink-0">{icon}</span>}
      </span>
    </motion.button>
  )
}
