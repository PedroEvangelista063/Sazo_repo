import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ProductCard } from '../components/ProductCard'
import type { ProdutoVarejo } from '../types/domain'

const baseProduct: ProdutoVarejo = {
  id_produto: 1,
  nome_produto: 'TOMATE',
  icone_url: null,
  uf: 'SP',
  municipio: 'São Paulo',
  municipio_id: '3550308',
  ano: 2025,
  mes: 6,
  data_referencia_atual: '2025-06-15',
  preco_estimado: false,
  usou_fallback_12m: false,
  status_cor: 'VERDE',
  fonte: 'CONAB',
  categoria: 'ALIMENTO_VAREJO',
  is_forecast: false,
  confianca_baseline: null,
  tendencia_futura: null,
  regiao: null,
}

function makeProduct(overrides: Partial<ProdutoVarejo>): ProdutoVarejo {
  return { ...baseProduct, ...overrides }
}

describe('ProductCard', () => {
  // Teste 1: Renderiza cores do semáforo corretamente
  it('renderiza "Melhor Época!" quando status_cor for VERDE', () => {
    render(<ProductCard product={makeProduct({ status_cor: 'VERDE' })} />)
    expect(screen.getByText('Melhor Época!')).toBeInTheDocument()
    expect(screen.getByRole('img', { name: 'TOMATE' })).toBeInTheDocument()
  })

  it('renderiza "Preço Normal" quando status_cor for AMARELO', () => {
    render(<ProductCard product={makeProduct({ status_cor: 'AMARELO' })} />)
    expect(screen.getByText('Preço Normal')).toBeInTheDocument()
  })

  it('renderiza "Péssima Época" quando status_cor for VERMELHO', () => {
    render(<ProductCard product={makeProduct({ status_cor: 'VERMELHO' })} />)
    expect(screen.getByText('Péssima Época')).toBeInTheDocument()
  })

  // Teste 2: Emoji de Fallback
  it('renderiza emoji de fallback 🛒 para produto sem emoji mapeado', () => {
    render(<ProductCard product={makeProduct({ nome_produto: 'PRODUTO DESCONHECIDO XYZ' })} />)
    expect(screen.getByText('🛒')).toBeInTheDocument()
  })

  it('renderiza emoji correto para produto mapeado', () => {
    render(<ProductCard product={makeProduct({ nome_produto: 'BANANA' })} />)
    expect(screen.getByText('🍌')).toBeInTheDocument()
  })

  it('renderiza nome do produto', () => {
    render(<ProductCard product={makeProduct({ nome_produto: 'BATATA' })} />)
    expect(screen.getByText('BATATA')).toBeInTheDocument()
  })

  // Teste 3: Sem "R$"
  it('não exibe R$ em nenhum lugar do card', () => {
    render(<ProductCard product={makeProduct({})} />)
    expect(screen.queryByText(/\$/)).not.toBeInTheDocument()
    expect(screen.queryByText(/R\$/)).not.toBeInTheDocument()
  })

  // Transparência temporal (V17) — sem badges sintéticos 📊/🪄
  it('exibe badge "Coleta Efetiva" quando tipo_dado for REAL_ATUAL', () => {
    render(
      <ProductCard
        product={makeProduct({
          ano_referencia: 2026,
          tipo_dado: 'REAL_ATUAL',
          is_dado_legado: false,
        })}
      />,
    )
    expect(screen.getAllByText(/Coleta Efetiva/).length).toBeGreaterThan(0)
  })

  it('exibe badge histórico + ano quando tipo_dado for HISTORICO_BASE', () => {
    render(
      <ProductCard
        product={makeProduct({
          ano_referencia: 2025,
          tipo_dado: 'HISTORICO_BASE',
          is_dado_legado: true,
        })}
      />,
    )
    expect(screen.getAllByText(/Histórico Real/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/'25/).length).toBeGreaterThan(0)
  })

  it('não exibe badges sintéticos 📊 Estimativa / 🪄 Estimado', () => {
    render(
      <ProductCard
        product={makeProduct({
          is_forecast: true,
          preco_estimado: true,
          confianca_baseline: 85,
          tipo_dado: 'HISTORICO_BASE',
          ano_referencia: 2025,
        })}
      />,
    )
    expect(screen.queryByText(/📊 Estimativa/)).not.toBeInTheDocument()
    expect(screen.queryByText(/🪄 Estimado/)).not.toBeInTheDocument()
  })

  it('exibe rodapé com ano de apuração quando há ano_referencia', () => {
    render(
      <ProductCard
        product={makeProduct({
          ano_referencia: 2025,
          tipo_dado: 'HISTORICO_BASE',
          is_dado_legado: true,
        })}
      />,
    )
    expect(screen.getByText(/Ano de apuração: 2025/)).toBeInTheDocument()
  })

  // Fallback 12m
  it('exibe * Média 12 meses quando usou_fallback_12m for true', () => {
    render(<ProductCard product={makeProduct({ usou_fallback_12m: true })} />)
    expect(screen.getByText('* Média 12 meses')).toBeInTheDocument()
  })
})
