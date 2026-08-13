import { Component, type ErrorInfo, type ReactNode } from 'react'
import { Button } from './ui/button'

interface ErrorBoundaryProps {
  children: ReactNode
}

interface ErrorBoundaryState {
  hasError: boolean
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { hasError: false }

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { hasError: true }
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo): void {
    console.error('[ErrorBoundary] Erro capturado:', error, errorInfo)
  }

  private handleReload = (): void => {
    window.location.reload()
  }

  render(): ReactNode {
    if (this.state.hasError) {
      return (
        <div className="flex min-h-screen items-center justify-center bg-surface-container p-6">
          <div className="clay-card flex w-full max-w-md flex-col items-center gap-6 rounded-3xl bg-surface-container p-8 text-center">
            <span className="text-5xl" role="img" aria-label="Escudo de proteção">
              🛡️
            </span>
            <div className="space-y-2">
              <h1 className="text-2xl font-bold text-on-surface">Ops! Algo deu errado</h1>
              <p className="text-on-surface-variant">
                Ops! Ocorreu um erro ao carregar os dados. Tente novamente.
              </p>
            </div>
            <Button variant="clay" onClick={this.handleReload}>
              Recarregar
            </Button>
          </div>
        </div>
      )
    }

    return this.props.children
  }
}
