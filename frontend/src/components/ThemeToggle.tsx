import { ActionIcon, useMantineColorScheme } from '@mantine/core'
import { Sun, Moon } from 'lucide-react'

export function ThemeToggle() {
  const { colorScheme, toggleColorScheme } = useMantineColorScheme()
  const isDark = colorScheme === 'dark'
  return (
    <ActionIcon
      onClick={toggleColorScheme}
      variant="default"
      size="lg"
      aria-label={isDark ? 'Ativar modo claro' : 'Ativar modo escuro'}
    >
      {isDark ? <Sun size={18} /> : <Moon size={18} />}
    </ActionIcon>
  )
}
