import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { SazonalidadeNacional } from '../components/SazonalidadeNacional'
import type { SazonalidadeNacionalItem } from '../types/domain'

const baseItem: SazonalidadeNacionalItem = {
  produto: 'TOMATE',
  classificao_produto: 'HORTALICA',
  categoria: 'HORTIFRUTI',
  total_ufs: 20,
  meses: [],
}

function makeItem(overrides: Partial<SazonalidadeNacionalItem>): SazonalidadeNacionalItem {
  return { ...baseItem, ...overrides }
}

describe('SazonalidadeNacional', () => {
  it("renderiza badge de ano legado '25 + ícone (i) em célula histórica", () => {
    render(
      <SazonalidadeNacional
        data={[
          makeItem({
            meses: [
              {
                mes: 6,
                status_cor: 'AMARELO',
                is_forecast: false,
                baseline_confianca: null,
                forecast_method: null,
                calculado_em: null,
                ano_referencia: 2025,
                tipo_dado: 'HISTORICO_BASE',
                is_dado_legado: true,
              },
            ],
          }),
        ]}
      />,
    )
    // Célula preenchida com badge do ano âncora
    expect(screen.getAllByText(/'25/).length).toBeGreaterThan(0)
  })

  it('renderiza ícone (i) de transparência na célula histórica', () => {
    render(
      <SazonalidadeNacional
        data={[
          makeItem({
            meses: [
              {
                mes: 6,
                status_cor: 'AMARELO',
                is_forecast: false,
                baseline_confianca: null,
                forecast_method: null,
                calculado_em: null,
                ano_referencia: 2024,
                tipo_dado: 'HISTORICO_BASE',
                is_dado_legado: true,
              },
            ],
          }),
        ]}
      />,
    )
    expect(screen.getAllByRole('button', { name: /informação/i }).length).toBeGreaterThan(0)
  })

  it('célula sem dados é vazia (muted) — sem tooltip de gap estrutural', () => {
    render(
      <SazonalidadeNacional
        data={[
          makeItem({
            total_ufs: 1,
            meses: [
              {
                mes: 1,
                status_cor: 'VERDE',
                is_forecast: false,
                baseline_confianca: null,
                forecast_method: null,
                calculado_em: null,
              },
            ],
          }),
        ]}
      />,
    )
    expect(screen.queryByText(/CONAB não publicou dados/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/scraper pendente/i)).not.toBeInTheDocument()
  })

  it('não renderiza R$ no DOM da grade (S3)', () => {
    const { container } = render(
      <SazonalidadeNacional
        data={[
          makeItem({
            meses: [
              {
                mes: 6,
                status_cor: 'AMARELO',
                is_forecast: false,
                baseline_confianca: null,
                forecast_method: null,
                calculado_em: null,
                ano_referencia: 2025,
                tipo_dado: 'HISTORICO_BASE',
                is_dado_legado: true,
              },
            ],
          }),
        ]}
      />,
    )
    expect(container.textContent).not.toContain('R$')
  })

  it('célula CINZA fica inativa com texto "Sem Cotação" + ícone (i) e sem badge de ano', () => {
    const { container } = render(
      <SazonalidadeNacional
        data={[
          makeItem({
            meses: [
              {
                mes: 3,
                status_cor: 'CINZA',
                is_forecast: false,
                baseline_confianca: null,
                forecast_method: null,
                calculado_em: null,
                tipo_dado: null,
                mensagem_transparencia: 'Sem histórico real para este período.',
              },
            ],
          }),
        ]}
      />,
    )
    expect(screen.getAllByText('Sem Cotação').length).toBeGreaterThan(0)
    expect(screen.getAllByRole('button', { name: /informação/i }).length).toBeGreaterThan(0)
    expect(container.textContent).toContain('Sem histórico real para este período.')
    // CINZA não tem ano âncora → nenhum badge de ano no DOM
    expect(container.textContent).not.toMatch(/'\d{2}/)
    expect(container.textContent).not.toContain('R$')
  })
})
