import { useEffect } from 'react'
import { useMantineColorScheme } from '@mantine/core'
import { useDataStream } from './hooks/useDataStream'
import { SupermercadoView } from './pages/SupermercadoView'

function useSyncDarkMode() {
  const { colorScheme } = useMantineColorScheme()
  useEffect(() => {
    const root = document.documentElement
    if (colorScheme === 'dark') {
      root.classList.add('dark')
    } else {
      root.classList.remove('dark')
    }
  }, [colorScheme])
}

export default function App() {
  useSyncDarkMode()
  useDataStream()
  return <SupermercadoView />
}
