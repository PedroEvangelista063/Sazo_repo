import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { PainelTransparenciaRodape } from '../components/PainelTransparenciaRodape'
import { setTransparency } from '../services/transparencyStore'

describe('PainelTransparenciaRodape', () => {
  beforeEach(() => {
    setTransparency({ lastRefresh: null, cacheStatus: null })
  })

  it('não renderiza nada sem X-Last-Refresh', () => {
    const { container } = render(<PainelTransparenciaRodape />)
    expect(container.firstChild).toBeNull()
  })

  it('exibe "Última atualização dos dados: DD/MM/AAAA às HH:MM"', () => {
    const iso = '2026-08-05T14:30:00Z'
    const d = new Date(iso)
    const dd = String(d.getDate()).padStart(2, '0')
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const hh = String(d.getHours()).padStart(2, '0')
    const min = String(d.getMinutes()).padStart(2, '0')

    setTransparency({ lastRefresh: iso, cacheStatus: 'MISS' })
    render(<PainelTransparenciaRodape />)

    expect(
      screen.getByText(
        new RegExp(`Última atualização dos dados: ${dd}/${mm}/${d.getFullYear()} às ${hh}:${min}`),
      ),
    ).toBeInTheDocument()
  })

  it('mostra indicador discreto de cache quando X-Cache-Status é HIT', () => {
    setTransparency({ lastRefresh: '2026-08-05T14:30:00Z', cacheStatus: 'HIT' })
    render(<PainelTransparenciaRodape />)
    expect(screen.getByLabelText(/cache/i)).toBeInTheDocument()
    expect(screen.getByText('cache')).toBeInTheDocument()
  })

  it('não mostra indicador de cache quando X-Cache-Status é MISS', () => {
    setTransparency({ lastRefresh: '2026-08-05T14:30:00Z', cacheStatus: 'MISS' })
    render(<PainelTransparenciaRodape />)
    expect(screen.queryByLabelText(/cache/i)).not.toBeInTheDocument()
  })
})
