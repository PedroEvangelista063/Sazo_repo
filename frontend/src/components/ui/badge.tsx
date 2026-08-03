import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const badgeVariants = cva(
  'inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold transition-colors focus:outline-none focus:ring-2 focus:ring-sazonal-verde-600 focus:ring-offset-2',
  {
    variants: {
      variant: {
        default:
          'border-transparent bg-sazonal-verde-600 text-white shadow hover:bg-sazonal-verde-700',
        secondary:
          'border-transparent bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-gray-100 hover:bg-gray-200 dark:hover:bg-gray-600',
        destructive:
          'border-transparent bg-sazonal-vermelho-600 text-white shadow hover:bg-sazonal-vermelho-700',
        outline: 'text-gray-900 dark:text-gray-100',
        warning:
          'border-transparent bg-sazonal-amarelo-400 text-white shadow hover:bg-sazonal-amarelo-600',
      },
    },
    defaultVariants: {
      variant: 'default',
    },
  },
)

export interface BadgeProps
  extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <div className={cn(badgeVariants({ variant }), className)} {...props} />
}

export { Badge, badgeVariants }
