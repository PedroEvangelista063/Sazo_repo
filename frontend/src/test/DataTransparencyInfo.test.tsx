import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { DataTransparencyInfo } from '../components/DataTransparencyInfo'

describe('DataTransparencyInfo', () => {
  it('renderiza nada quando !tipo_dado (contrato aditivo)', () => {
    const { container } = render(<DataTransparencyInfo tipo_dado={null} />)
    expect(container.firstChild).toBeNull()
  })

  it('mostra "Dado Atual" + "Coleta Efetiva" para REAL_ATUAL de 2026', async () => {
    render(
      <DataTransparencyInfo tipo_dado="REAL_ATUAL" ano_referencia={2026} is_dado_legado={false} />,
    )
    const btn = screen.getByRole('button', { name: /informação/i })
    expect(btn).toBeInTheDocument()
  })

  it('não renderiza R$ no DOM (S3/R-ADD-03)', () => {
    const { container } = render(
      <DataTransparencyInfo
        tipo_dado="HISTORICO_BASE"
        ano_referencia={2025}
        is_dado_legado={true}
        mensagem_transparencia="Dado histórico real — CONAB 2025 (defasagem de 1 ano)."
      />,
    )
    expect(container.querySelector('[aria-label*="informação"]')).toBeInTheDocument()
    expect(container.textContent).not.toContain('R$')
    expect(container.textContent).not.toMatch(/R\s?\$/i)
  })

  it('expõe mensagem_transparencia quando fornecida', () => {
    const { container } = render(
      <DataTransparencyInfo
        tipo_dado="HISTORICO_BASE"
        ano_referencia={2025}
        is_dado_legado={true}
        mensagem_transparencia="Dado histórico real — última cotação da CONAB em 2025 (defasagem de 1 ano)."
      />,
    )
    expect(container.textContent).toContain('2025')
    expect(container.textContent).not.toContain('R$')
  })

  it('renderiza tooltip "Sem Cotação" com mensagem_transparencia quando status_cor=CINZA', () => {
    const { container } = render(
      <DataTransparencyInfo
        status_cor="CINZA"
        tipo_dado={null}
        mensagem_transparencia="Sem histórico real para este período."
      />,
    )
    expect(screen.getByRole('button', { name: /informação/i })).toBeInTheDocument()
    expect(container.textContent).toContain('Sem Cotação')
    expect(container.textContent).toContain('Sem histórico real para este período.')
    expect(container.textContent).not.toContain('R$')
  })
})
