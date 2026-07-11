import { useTheme } from '../hooks/useTheme'
import { Button } from './ui/button'
import { Sun, Moon } from 'lucide-react'

export function ThemeToggle() {
  const { isDark, toggleTheme } = useTheme()
  return (
    <Button
      onClick={toggleTheme}
      variant="outline"
      size="icon-lg"
      aria-label={isDark ? 'Ativar modo claro' : 'Ativar modo escuro'}
    >
      {isDark ? <Sun size={18} /> : <Moon size={18} />}
    </Button>
  )
}
