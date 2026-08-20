import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { BrasilMap } from '../components/BrasilMap'
import type { BoletimFlowItem, FlowItem } from '../types/domain'

/* ── helpers ───────────────────────────────────────────────────────────────── */

const boletimFlow = (over: Partial<BoletimFlowItem> = {}): BoletimFlowItem => ({
  id: 1,
  produto: 'milho',
  origem_uf: 'MT',
  origem_polo: 'SORRISO',
  destino_uf: 'PA',
  destino_polo: 'MIRITITUBA',
  mes_referencia: 7,
  ano_referencia: 2026,
  fonte: 'boletim-logistico-julho-2026',
  pagina: 4,
  ...over,
})

const staticFlow = (over: Partial<FlowItem> = {}): FlowItem => ({
  id: 10,
  item: 'Milho',
  origem_uf: 'GO',
  origem_polo: 'GOIÂNIA',
  destino_uf: 'SP',
  destino_regiao_id: 'sudeste',
  meses: [1, 2],
  sazonalidade: 'q1',
  preco_referencial: 'R$ 25',
  tipo: 'exportado',
  ...over,
})

const baseProps = {
  selectedRegion: null as string | null,
  onRegionClick: vi.fn(),
  selectedUF: null as string | null,
  onUfClick: vi.fn(),
}

/* ── BrasilMap + Boletins CONAB ──────────────────────────────────────────── */

describe('BrasilMap — boletimFlows (Fluxos / Boletins CONAB)', () => {
  it('renderiza sem erros quando boletimFlows está ativo com dados', () => {
    const { container } = render(<BrasilMap {...baseProps} boletimFlows={[boletimFlow()]} />)
    // Arcos SVG devem estar presentes
    const paths = container.querySelectorAll('path[d]')
    expect(paths.length).toBeGreaterThan(0)
    // Label dos estados (27 UFs)
    expect(screen.getAllByRole('button').length).toBeGreaterThanOrEqual(27)
  })

  it('não quebra com boletimFlows vazio (array [])', () => {
    const { container } = render(<BrasilMap {...baseProps} boletimFlows={[]} />)
    expect(container.querySelector('svg')).toBeTruthy()
  })

  it('não quebra com boletimFlows null (estado CINZA)', () => {
    const { container } = render(
      <BrasilMap {...baseProps} boletimFlows={null as unknown as BoletimFlowItem[]} />,
    )
    expect(container.querySelector('svg')).toBeTruthy()
  })

  it('não quebra com boletimFlows undefined (prop ausente)', () => {
    const { container } = render(<BrasilMap {...baseProps} />)
    expect(container.querySelector('svg')).toBeTruthy()
  })

  it('não quebra com todos os props null/undefined (estado vazio)', () => {
    const { container } = render(
      <BrasilMap
        selectedRegion={null}
        onRegionClick={vi.fn()}
        selectedUF={null}
        onUfClick={vi.fn()}
        fluxos={undefined}
        boletimFlows={undefined}
      />,
    )
    expect(container.querySelector('svg')).toBeTruthy()
  })

  it('não quebra com fluxos e boletimFlows ambos nulos', () => {
    const { container } = render(
      <BrasilMap
        selectedRegion={null}
        onRegionClick={vi.fn()}
        selectedUF={null}
        onUfClick={vi.fn()}
        fluxos={null as unknown as FlowItem[]}
        boletimFlows={null as unknown as BoletimFlowItem[]}
      />,
    )
    expect(container.querySelector('svg')).toBeTruthy()
  })
})

/* ── Null Safety: polos ausentes ─────────────────────────────────────────── */

describe('BrasilMap — null safety nos polos', () => {
  it('renderiza com origem_polo e destino_polo null', () => {
    const { container } = render(
      <BrasilMap
        {...baseProps}
        boletimFlows={[boletimFlow({ origem_polo: null, destino_polo: null })]}
      />,
    )
    const paths = container.querySelectorAll('path[d]')
    expect(paths.length).toBeGreaterThan(0)
  })

  it('renderiza com origem_polo e destino_polo undefined', () => {
    const { container } = render(
      <BrasilMap
        {...baseProps}
        boletimFlows={[boletimFlow({ origem_polo: undefined, destino_polo: undefined })]}
      />,
    )
    expect(container.querySelector('svg')).toBeTruthy()
  })

  it('renderiza com fonte e pagina null', () => {
    const { container } = render(
      <BrasilMap {...baseProps} boletimFlows={[boletimFlow({ fonte: null, pagina: null })]} />,
    )
    expect(container.querySelector('svg')).toBeTruthy()
  })
})

/* ── Arcos com UF filtrada ───────────────────────────────────────────────── */

describe('BrasilMap — boletimFlows com selectedUF', () => {
  it('filtra arcos por UF de destino (incoming)', () => {
    const { container } = render(
      <BrasilMap
        {...baseProps}
        selectedUF="PA"
        boletimFlows={[boletimFlow({ origem_uf: 'MT', destino_uf: 'PA' })]}
      />,
    )
    const paths = container.querySelectorAll('path[d]')
    expect(paths.length).toBeGreaterThan(0)
  })

  it('filtra arcos por UF de origem (outgoing)', () => {
    const { container } = render(
      <BrasilMap
        {...baseProps}
        selectedUF="MT"
        boletimFlows={[boletimFlow({ origem_uf: 'MT', destino_uf: 'PA' })]}
      />,
    )
    const paths = container.querySelectorAll('path[d]')
    expect(paths.length).toBeGreaterThan(0)
  })

  it('não exibe arcos quando selectedUF não está nos dados', () => {
    const { container } = render(
      <BrasilMap
        {...baseProps}
        selectedUF="SP"
        boletimFlows={[boletimFlow({ origem_uf: 'MT', destino_uf: 'PA' })]}
      />,
    )
    // Somente paths do mapa base (region hulls), sem arcos de fluxo
    const flowPaths = container.querySelectorAll('path[d*="Q"]')
    expect(flowPaths.length).toBe(0)
  })
})

/* ── Arcos de fluxos estáticos ───────────────────────────────────────────── */

describe('BrasilMap — staticArcs (fluxos históricos)', () => {
  it('renderiza arcos estáticos quando fluxos presentes', () => {
    const { container } = render(<BrasilMap {...baseProps} fluxos={[staticFlow()]} />)
    // Arcos estáticos ficam ocultos até o toggle "Fluxos" ser pressionado
    fireEvent.click(screen.getByText(/Fluxos/))
    const flowPaths = container.querySelectorAll('path[d*="Q"]')
    expect(flowPaths.length).toBeGreaterThan(0)
  })

  it('mostra botão "Fluxos" quando fluxos presentes e sem selectedUF', () => {
    render(<BrasilMap {...baseProps} fluxos={[staticFlow()]} />)
    expect(screen.getByText(/Fluxos/)).toBeTruthy()
  })

  it('não exibe botão Fluxos quando selectedUF ativo', () => {
    render(<BrasilMap {...baseProps} selectedUF="GO" fluxos={[staticFlow()]} />)
    expect(screen.queryByText(/Fluxos/)).toBeNull()
  })
})

/* ── Interação: toggle Fluxos ─────────────────────────────────────────────── */

describe('BrasilMap — toggle showFluxos', () => {
  it('alterna visibilidade dos arcos estáticos ao clicar no botão', () => {
    const { container } = render(<BrasilMap {...baseProps} fluxos={[staticFlow()]} />)
    // Initially arcs are hidden (showFluxos = false)
    let flowPaths = container.querySelectorAll('g.pointer-events-none path[d*="Q"]')
    expect(flowPaths.length).toBe(0)

    // Click toggle button
    const toggle = screen.getByText(/Fluxos/)
    fireEvent.click(toggle)

    // Now arcs should be visible
    flowPaths = container.querySelectorAll('g.pointer-events-none path[d*="Q"]')
    expect(flowPaths.length).toBeGreaterThan(0)

    // Click again to hide
    fireEvent.click(screen.getByText(/Ocultar Fluxos/))
    flowPaths = container.querySelectorAll('g.pointer-events-none path[d*="Q"]')
    expect(flowPaths.length).toBe(0)
  })
})

/* ── Interação: clique em UF ──────────────────────────────────────────────── */

describe('BrasilMap — clique em UF com boletimFlows', () => {
  it('chama onUfClick ao clicar em um dot de UF', () => {
    const onUfClick = vi.fn()
    render(<BrasilMap {...baseProps} onUfClick={onUfClick} boletimFlows={[boletimFlow()]} />)

    const spButton = screen.getByRole('button', { name: /SP.*São Paulo/ })
    fireEvent.click(spButton)
    expect(onUfClick).toHaveBeenCalledWith('SP')
  })

  it('renderiza badge de navegação quando selectedUF + onUfNavigate', () => {
    render(
      <BrasilMap
        {...baseProps}
        selectedUF="MT"
        onUfNavigate={vi.fn()}
        boletimFlows={[boletimFlow()]}
      />,
    )
    expect(screen.getByText(/Ver Cards de/)).toBeTruthy()
  })

  it('fallback para selectedUF quando ufData não encontrado', () => {
    render(<BrasilMap {...baseProps} selectedUF="ZZ" onUfNavigate={vi.fn()} boletimFlows={[]} />)
    expect(screen.getByText(/Ver Cards de ZZ/)).toBeTruthy()
  })
})

/* ── Tooltip de boletim ───────────────────────────────────────────────────── */

describe('BrasilMap — tooltip boletim', () => {
  it('não renderiza tooltip inicialmente', () => {
    render(<BrasilMap {...baseProps} boletimFlows={[boletimFlow()]} />)
    expect(screen.queryByText(/milho/)).toBeNull()
  })
})

/* ── onTableNavigate ──────────────────────────────────────────────────────── */

describe('BrasilMap — onTableNavigate', () => {
  it('renderiza botão 🇧🇷 quando onTableNavigate presente', () => {
    render(<BrasilMap {...baseProps} onTableNavigate={vi.fn()} />)
    expect(screen.getByText('🇧🇷')).toBeTruthy()
    expect(screen.getByText('Tabela')).toBeTruthy()
  })

  it('não renderiza botão 🇧🇷 quando onTableNavigate ausente', () => {
    render(<BrasilMap {...baseProps} />)
    expect(screen.queryByText('🇧🇷')).toBeNull()
  })
})

/* ── Legendas das regiões ─────────────────────────────────────────────────── */

describe('BrasilMap — legendas das regiões', () => {
  it('renderiza os 5 botões de região', () => {
    render(<BrasilMap {...baseProps} />)
    expect(screen.getByText('Norte')).toBeTruthy()
    expect(screen.getByText('Nordeste')).toBeTruthy()
    expect(screen.getByText('Centro-Oeste')).toBeTruthy()
    expect(screen.getByText('Sudeste')).toBeTruthy()
    expect(screen.getByText('Sul')).toBeTruthy()
  })

  it('chama onRegionClick ao clicar em uma região', () => {
    const onRegionClick = vi.fn()
    render(<BrasilMap {...baseProps} onRegionClick={onRegionClick} />)
    fireEvent.click(screen.getByText('Sul'))
    expect(onRegionClick).toHaveBeenCalledWith('sul')
  })
})

/* ── Múltiplos boletimFlows (mega stress) ────────────────────────────────── */

describe('BrasilMap — múltiplos boletimFlows', () => {
  it('renderiza sem erros com 50 boletimFlows', () => {
    const flows = Array.from({ length: 50 }, (_, i) =>
      boletimFlow({
        id: i + 1,
        origem_uf: ['MT', 'GO', 'MS', 'BA', 'SP'][i % 5],
        destino_uf: ['PA', 'AM', 'CE', 'PE', 'RJ'][i % 5],
      }),
    )
    const { container } = render(<BrasilMap {...baseProps} boletimFlows={flows} />)
    expect(container.querySelector('svg')).toBeTruthy()
    const paths = container.querySelectorAll('path[d*="Q"]')
    expect(paths.length).toBeGreaterThan(0)
  })
})
