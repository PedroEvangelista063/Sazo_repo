import { useTheme } from './hooks/useTheme'
import { useDataStream } from './hooks/useDataStream'
import { SupermercadoView } from './pages/SupermercadoView'

export default function App() {
  useTheme()
  useDataStream()
  return <SupermercadoView />
}
