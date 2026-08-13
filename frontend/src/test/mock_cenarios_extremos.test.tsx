import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ProductCard } from '../components/ProductCard'
import { ErrorBoundary } from '../components/ErrorBoundary'
import { DataTransparencyInfo } from '../components/DataTransparencyInfo'
import type { ProdutoVarejo } from '../types/domain'

const baseProduct: ProdutoVarejo = {
  id_produto: 1,
  nome_produto: 'COENTRO',
  icone_url: null,
  uf: 'SP',
  municipio: 'São Paulo',
  municipio_id: '3550308',
  ano: 2026,
  mes: 8,
  data_referencia_atual: '2026-08-01',
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

describe('Cenário 1 — Sensibilidade de Centavos (Maço de Coentro)', () => {
  // `metadado_transparencia` (mock do usuário) não existe no tipo — o campo real é
  // `mensagem_transparencia`. Não há `preco_atual`/`preco_referencia` no ProdutoVarejo.
  const coentroMock = makeProduct({
    nome_produto: 'COENTRO',
    status_cor: 'VERMELHO',
    mensagem_transparencia: 'Variação severa detectada.',
  })

  it('renderiza o card sem crash com status VERMELHO', () => {
    render(<ProductCard product={coentroMock} />)
    expect(screen.getByText('COENTRO')).toBeInTheDocument()
    // Texto real do componente (STATUS_BADGES.VERMELHO em ProductCard.tsx:69):
    expect(screen.getByText('🔴 Época Ruim — Caro')).toBeInTheDocument()
  })

  it('mensagem "Variação severa detectada." não dispara subtítulo de projeção', () => {
    render(<ProductCard product={coentroMock} />)
    expect(screen.queryByText('Projeção baseada em anos anteriores')).not.toBeInTheDocument()
  })
})

describe('Cenário 2 — Série Contaminada (Pitaya RJ)', () => {
  // O metadado JSON '{"fonte": "PROJECAO", ...}' não é lido pelo frontend — o tipo expõe
  // `tipo_dado` + `mensagem_transparencia` planos. Mapeamos para o contrato real.
  const pitayaMock = makeProduct({
    nome_produto: 'PITAYA',
    uf: 'RJ',
    status_cor: 'AMARELO',
    tipo_dado: 'PROJECAO',
    mensagem_transparencia: 'Série com variabilidade extrema. Baixa confiabilidade.',
  })

  it('renderiza sem crash com status AMARELO', () => {
    render(<ProductCard product={pitayaMock} />)
    expect(screen.getByText('🟡 Estável — Preço Normal')).toBeInTheDocument()
    expect(screen.getByText('PITAYA')).toBeInTheDocument()
  })

  it('tipo_dado PROJECAO dispara aviso de projeção com a mensagem real de transparência', () => {
    render(<ProductCard product={pitayaMock} />)
    expect(
      screen.getByText('Série com variabilidade extrema. Baixa confiabilidade.'),
    ).toBeInTheDocument()
  })

  it('FIX Cenário 2: aviso específico de baixa confiabilidade agora está no DOM do ProductCard', () => {
    render(<ProductCard product={pitayaMock} />)
    expect(screen.getByText(/Série com variabilidade extrema/i)).toBeInTheDocument()
    expect(screen.getByText(/Baixa confiabilidade/i)).toBeInTheDocument()
  })

  it('PROBE: DataTransparencyInfo (não conectado ao ProductCard) consegue expor a mensagem', () => {
    const { container } = render(
      <DataTransparencyInfo
        tipo_dado="PROJECAO"
        mensagem_transparencia="Série com variabilidade extrema. Baixa confiabilidade."
      />,
    )
    expect(container.textContent).toContain('Baixa confiabilidade')
  })
})

describe('Cenário 3 — Tratamento de Nulos/Erros (Timeout → ErrorBoundary)', () => {
  function Boom(): never {
    throw new Error('network timeout simulado')
  }

  it('fallback do ErrorBoundary aparece em vez de tela branca', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      render(
        <ErrorBoundary>
          <Boom />
        </ErrorBoundary>,
      )
      expect(
        screen.getByText('Ops! Ocorreu um erro ao carregar os dados. Tente novamente.'),
      ).toBeInTheDocument()
      expect(screen.getByText('Recarregar')).toBeInTheDocument()
    } finally {
      spy.mockRestore()
    }
  })
})
