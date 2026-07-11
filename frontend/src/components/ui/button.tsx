import * as React from 'react'
import { Slot } from '@radix-ui/react-slot'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-sazonal-verde-600 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0',
  {
    variants: {
      variant: {
        default:
          'bg-sazonal-verde-600 text-white shadow hover:bg-sazonal-verde-700',
        destructive:
          'bg-sazonal-vermelho-600 text-white shadow-sm hover:bg-sazonal-vermelho-700',
        outline:
          'border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 shadow-sm hover:bg-gray-100 dark:hover:bg-gray-700',
        secondary:
          'bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-gray-100 shadow-sm hover:bg-gray-200 dark:hover:bg-gray-600',
        ghost: 'hover:bg-gray-100 dark:hover:bg-gray-700',
        link: 'text-sazonal-verde-600 underline-offset-4 hover:underline',
        green: 'bg-sazonal-verde-600 text-white shadow-sm hover:bg-sazonal-verde-700',
        light: 'bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20 text-sazonal-verde-700 dark:text-sazonal-verde-400 hover:bg-sazonal-verde-100 dark:hover:bg-sazonal-verde-dark/30',
      },
      size: {
        default: 'h-9 px-4 py-2',
        sm: 'h-8 rounded-md px-3 text-xs',
        lg: 'h-10 rounded-md px-8',
        icon: 'h-9 w-9',
        'icon-lg': 'h-10 w-10',
      },
    },
    defaultVariants: {
      variant: 'default',
      size: 'default',
    },
  },
)

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : 'button'
    return (
      <Comp
        className={cn(buttonVariants({ variant, size, className }))}
        ref={ref}
        {...props}
      />
    )
  },
)
Button.displayName = 'Button'

export { Button, buttonVariants }
