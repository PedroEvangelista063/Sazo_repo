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
  // Teste 1: Círculo de cor do semáforo (novo contrato claymorphism)
  it('renderiza círculo de cor verde quando status_cor for VERDE', () => {
    const { container } = render(<ProductCard product={makeProduct({ status_cor: 'VERDE' })} />)
    expect(container.querySelector('.bg-status-green')).not.toBeNull()
    expect(screen.getByText('🍅')).toBeInTheDocument()
    expect(screen.getByText('TOMATE')).toBeInTheDocument()
  })

  it('renderiza círculo de cor amarelo quando status_cor for AMARELO', () => {
    const { container } = render(<ProductCard product={makeProduct({ status_cor: 'AMARELO' })} />)
    expect(container.querySelector('.bg-status-yellow')).not.toBeNull()
    expect(screen.getByText('🍅')).toBeInTheDocument()
  })

  it('renderiza círculo de cor vermelho quando status_cor for VERMELHO', () => {
    const { container } = render(<ProductCard product={makeProduct({ status_cor: 'VERMELHO' })} />)
    expect(container.querySelector('.bg-status-red')).not.toBeNull()
    expect(screen.getByText('🍅')).toBeInTheDocument()
  })

  it('trata status desconhecido como AMARELO (fallback neutro, sem cinza)', () => {
    const { container } = render(
      <ProductCard
        product={makeProduct({ status_cor: 'DESCONHECIDO' as ProdutoVarejo['status_cor'] })}
      />,
    )
    // Fallback documentado: nunca cinza/vazio — usa o badge AMARELO neutro.
    expect(container.querySelector('.bg-status-yellow')).not.toBeNull()
    expect(container.querySelector('.bg-status-green')).toBeNull()
    expect(container.querySelector('.bg-status-red')).toBeNull()
    expect(screen.getByText('🟡 Estável — Preço Normal')).toBeInTheDocument()
  })

  // Teste 1b: Badge de semáforo linguístico (texto + cor)
  it('exibe badge linguístico VERDE "🟢 Época Boa — Barato"', () => {
    render(<ProductCard product={makeProduct({ status_cor: 'VERDE' })} />)
    expect(screen.getByText('🟢 Época Boa — Barato')).toBeInTheDocument()
  })

  it('exibe badge linguístico AMARELO "🟡 Estável — Preço Normal"', () => {
    render(<ProductCard product={makeProduct({ status_cor: 'AMARELO' })} />)
    expect(screen.getByText('🟡 Estável — Preço Normal')).toBeInTheDocument()
  })

  it('exibe badge linguístico VERMELHO "🔴 Época Ruim — Caro"', () => {
    render(<ProductCard product={makeProduct({ status_cor: 'VERMELHO' })} />)
    expect(screen.getByText('🔴 Época Ruim — Caro')).toBeInTheDocument()
  })

  it('mostra subtítulo de projeção quando is_forecast', () => {
    render(<ProductCard product={makeProduct({ is_forecast: true })} />)
    expect(screen.getByText('Projeção baseada em anos anteriores')).toBeInTheDocument()
  })

  it('mostra subtítulo de projeção para tipo_dado FALLBACK_DIMENSAO', () => {
    render(<ProductCard product={makeProduct({ tipo_dado: 'FALLBACK_DIMENSAO' })} />)
    expect(screen.getByText('Projeção baseada em anos anteriores')).toBeInTheDocument()
  })

  it('não mostra subtítulo de projeção para HISTORICO_BASE', () => {
    render(<ProductCard product={makeProduct({ tipo_dado: 'HISTORICO_BASE' })} />)
    expect(screen.queryByText('Projeção baseada em anos anteriores')).not.toBeInTheDocument()
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

  // Transparência temporal (V17) — card simplificado: sem badges de texto/dados
  it('não exibe badges de transparência de dados no card simplificado', () => {
    render(
      <ProductCard
        product={makeProduct({
          ano_referencia: 2025,
          tipo_dado: 'HISTORICO_BASE',
          is_dado_legado: true,
          usou_fallback_12m: true,
        })}
      />,
    )
    expect(screen.queryByText(/Coleta Efetiva/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Histórico Real/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Ano de apuração/)).not.toBeInTheDocument()
    expect(screen.queryByText('* Média 12 meses')).not.toBeInTheDocument()
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

  // Seleção
  it('exibe check de seleção quando isSelected e onToggle estão presentes', () => {
    const { container } = render(
      <ProductCard product={makeProduct({})} isSelected onToggle={() => {}} />,
    )
    expect(container.querySelector('.lucide-check')).not.toBeNull()
  })

  it('não exibe check de seleção quando não selecionado', () => {
    const { container } = render(<ProductCard product={makeProduct({})} />)
    expect(container.querySelector('.lucide-check')).toBeNull()
  })
})
