import { useTheme } from '../hooks/useTheme'
import { Button } from './ui/button'
import { Sun, Moon } from 'lucide-react'
import { cn } from '@/lib/utils'

interface ThemeToggleProps {
  className?: string
}

export function ThemeToggle({ className }: ThemeToggleProps) {
  const { isDark, toggleTheme } = useTheme()
  return (
    <Button
      onClick={toggleTheme}
      variant="outline"
      size="icon-lg"
      aria-label={isDark ? 'Ativar modo claro' : 'Ativar modo escuro'}
      className={cn(
        'rounded-2xl shadow-clay-btn transition-all hover:shadow-clay-btn-hover active:translate-y-[1px] active:scale-[0.98] active:shadow-clay-press',
        className,
      )}
    >
      {isDark ? <Sun size={18} /> : <Moon size={18} />}
    </Button>
  )
}
