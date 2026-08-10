import { useTheme } from './hooks/useTheme'
import { useDataStream } from './hooks/useDataStream'
import { SupermercadoView } from './pages/SupermercadoView'
import { OnboardingFlyer } from './components/OnboardingFlyer'

export default function App() {
  useTheme()
  useDataStream()
  return (
    <>
      <SupermercadoView />
      <OnboardingFlyer />
    </>
  )
}
