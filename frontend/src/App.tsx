import { useTheme } from './hooks/useTheme'
import { useDataStream } from './hooks/useDataStream'
import { SupermercadoView } from './pages/SupermercadoView'

export default function App() {
  const { isDark, toggleTheme } = useTheme()
  useDataStream()
  return <SupermercadoView isDark={isDark} onToggleTheme={toggleTheme} />
}
