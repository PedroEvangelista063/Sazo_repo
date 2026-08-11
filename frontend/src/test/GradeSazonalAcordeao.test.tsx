import { describe, it, expect } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { GradeSazonalAcordeao } from '../components/GradeSazonalAcordeao'
import type { SazonalidadeNacionalItem } from '../types/domain'

function item(produto: string, categoria: string): SazonalidadeNacionalItem {
  return {
    produto,
    classificao_produto: null,
    categoria,
    total_ufs: 10,
    meses: [
      {
        mes: 1,
        status_cor: 'AMARELO',
        is_forecast: false,
        baseline_confianca: null,
        forecast_method: null,
        calculado_em: null,
      },
    ],
  }
}

const DATA: SazonalidadeNacionalItem[] = [
  item('BANANA', 'FRUTAS'),
  item('MACA', 'FRUTAS'), // Frutas = maior grupo (destaque)
  item('ALFACE', 'VERDURAS'),
  item('TOMATE', 'LEGUMES'),
  item('BATATA', 'LEGUMES'),
  item('FEIJAO', 'CEREAIS_GRAOS'),
]

describe('GradeSazonalAcordeao', () => {
  it('abre a categoria destaque (maior) por padrão e mantém as demais fechadas', () => {
    render(<GradeSazonalAcordeao data={DATA} />)

    // Frutas (destaque) aberta → produtos visíveis
    expect(screen.getByText('BANANA')).toBeInTheDocument()

    // Demais fechadas → conteúdo NÃO montado no DOM (lazy)
    expect(screen.queryByText('ALFACE')).not.toBeInTheDocument()
    expect(screen.queryByText('TOMATE')).not.toBeInTheDocument()
    expect(screen.queryByText('BATATA')).not.toBeInTheDocument()
    expect(screen.queryByText('FEIJAO')).not.toBeInTheDocument()
  })

  it('renderiza headers das macrocategorias com contagem e omite grupos vazios', () => {
    render(<GradeSazonalAcordeao data={DATA} />)

    expect(screen.getByRole('button', { name: /Frutas/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Verduras e Folhagens/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Legumes/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Tubérculos e Raízes/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Ovos, Grãos e Diversos/i })).toBeInTheDocument()

    // Grupo vazio (Outros) é omitido — asserção pela descrição única da categoria
    expect(
      screen.queryByRole('button', { name: /Sem classificação direta/i }),
    ).not.toBeInTheDocument()
  })

  it('expande ao clicar e permite múltiplos grupos abertos', () => {
    render(<GradeSazonalAcordeao data={DATA} />)

    // Abre Verduras
    fireEvent.click(screen.getByRole('button', { name: /Verduras e Folhagens/i }))
    expect(screen.getByText('ALFACE')).toBeInTheDocument()

    // Abre Legumes — Frutas continua aberta (múltiplos simultâneos)
    fireEvent.click(screen.getByRole('button', { name: /Legumes/i }))
    expect(screen.getByText('TOMATE')).toBeInTheDocument()
    expect(screen.getByText('BANANA')).toBeInTheDocument()
  })

  it('recolhe ao clicar de novo (toggle via aria-expanded)', () => {
    render(<GradeSazonalAcordeao data={DATA} />)
    const frutas = screen.getByRole('button', { name: /Frutas/i })
    expect(frutas.getAttribute('aria-expanded')).toBe('true')

    fireEvent.click(frutas)
    expect(frutas.getAttribute('aria-expanded')).toBe('false')
  })

  it('aplica sticky abaixo do header do app (top-[7.5rem]) no header da categoria', () => {
    render(<GradeSazonalAcordeao data={DATA} />)
    const header = screen.getByRole('button', { name: /Frutas/i })
    expect(header.className).toContain('sticky')
    expect(header.className).toContain('top-[7.5rem]')
  })

  it('com abrirDestaque=false tudo vem fechado', () => {
    render(<GradeSazonalAcordeao data={DATA} abrirDestaque={false} />)
    expect(screen.queryByText('BANANA')).not.toBeInTheDocument()
  })
})
