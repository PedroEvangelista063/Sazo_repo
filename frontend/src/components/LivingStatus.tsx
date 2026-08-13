import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'
import { glowPulse } from '@/lib/motion-presets'

export type StatusCor = 'VERDE' | 'AMARELO' | 'VERMELHO'

const STATUS_CONFIG: Record<
  StatusCor,
  {
    label: string
    bg: string
    text: string
    border: string
    dotColor: string
    glowColor: string
  }
> = {
  VERDE: {
    label: 'Melhor Época',
    bg: 'bg-sazonal-verde-100 dark:bg-sazonal-verde-dark/30',
    text: 'text-sazonal-verde-700 dark:text-sazonal-verde-400',
    border: 'border-sazonal-verde-600 dark:border-sazonal-verde-400',
    dotColor: '#16a34a',
    glowColor: '#16a34a',
  },
  AMARELO: {
    label: 'Preço Normal',
    bg: 'bg-sazonal-amarelo-100 dark:bg-sazonal-amarelo-dark/30',
    text: 'text-sazonal-amarelo-700 dark:text-sazonal-amarelo-400',
    border: 'border-sazonal-amarelo-600 dark:border-sazonal-amarelo-400',
    dotColor: '#ca8a04',
    glowColor: '#ca8a04',
  },
  VERMELHO: {
    label: 'Péssima Época',
    bg: 'bg-sazonal-vermelho-100 dark:bg-sazonal-vermelho-dark/30',
    text: 'text-sazonal-vermelho-700 dark:text-sazonal-vermelho-400',
    border: 'border-sazonal-vermelho-600 dark:border-sazonal-vermelho-400',
    dotColor: '#dc2626',
    glowColor: '#dc2626',
  },
}

interface LivingStatusProps {
  status: StatusCor | null | undefined
  size?: 'sm' | 'md' | 'lg'
  showLabel?: boolean
  className?: string
}

export function LivingStatus({
  status,
  size = 'md',
  showLabel = true,
  className,
}: LivingStatusProps) {
  const cfg = STATUS_CONFIG[status as StatusCor] ?? STATUS_CONFIG.VERDE

  const sizeStyles = {
    sm: 'px-2 py-0.5 text-[10px] gap-1',
    md: 'px-3 py-1 text-xs gap-1.5',
    lg: 'px-4 py-1.5 text-sm gap-2',
  }

  return (
    <motion.span
      initial={{ scale: 0.8, opacity: 0 }}
      animate={{ scale: 1, opacity: 1 }}
      transition={{ type: 'spring', stiffness: 500, damping: 25 }}
      className={cn(
        'inline-flex items-center rounded-full font-medium',
        sizeStyles[size],
        cfg.bg,
        cfg.text,
        cfg.border,
        className,
      )}
    >
      <motion.span
        className="h-1.5 w-1.5 flex-shrink-0 rounded-full"
        style={{ backgroundColor: cfg.dotColor }}
        animate={glowPulse(cfg.glowColor)}
        transition={{ duration: 2, repeat: Infinity, ease: 'easeInOut' }}
      />
      {showLabel && <span className="select-none">{cfg.label}</span>}
    </motion.span>
  )
}

interface StatusFilterChipsProps {
  selectedStatus: StatusCor | null
  onChange: (status: StatusCor | null) => void
  className?: string
}

export function StatusFilterChips({ selectedStatus, onChange, className }: StatusFilterChipsProps) {
  const chips: { value: StatusCor; label: string }[] = [
    { value: 'VERDE', label: 'Melhor Época' },
    { value: 'AMARELO', label: 'Preço Normal' },
    { value: 'VERMELHO', label: 'Péssima Época' },
  ]

  return (
    <div className={cn('flex flex-wrap gap-1.5', className)}>
      {chips.map(({ value, label }) => (
        <motion.button
          key={value}
          onClick={() => onChange(selectedStatus === value ? null : value)}
          initial={{ scale: 0.9 }}
          animate={{ scale: 1 }}
          whileHover={{ scale: 1.02 }}
          whileTap={{ scale: 0.97 }}
          className={cn(
            'inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium transition-all',
            selectedStatus === value
              ? `${STATUS_CONFIG[value].bg} ${STATUS_CONFIG[value].text} ${STATUS_CONFIG[value].border}`
              : 'border-gray-200 text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800',
          )}
          style={
            selectedStatus === value
              ? { boxShadow: `0 0 0 2px ${STATUS_CONFIG[value].dotColor}` }
              : undefined
          }
        >
          <motion.span
            className="h-1.5 w-1.5 rounded-full"
            style={{ backgroundColor: STATUS_CONFIG[value].dotColor }}
            animate={selectedStatus === value ? glowPulse(STATUS_CONFIG[value].dotColor) : {}}
            transition={{ duration: 2, repeat: Infinity, ease: 'easeInOut' }}
          />
          {label}
        </motion.button>
      ))}
      {selectedStatus && (
        <motion.button
          initial={{ scale: 0.9 }}
          animate={{ scale: 1 }}
          onClick={() => onChange(null)}
          className="p-1 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300"
          aria-label="Limpar filtro"
        >
          <svg className="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </motion.button>
      )}
    </div>
  )
}
