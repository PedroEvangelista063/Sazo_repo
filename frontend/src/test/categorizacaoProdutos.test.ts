import { describe, it, expect } from 'vitest'
import {
  agruparPorMacrocategoria,
  getMacrocategoriaId,
  MACROCATEGORIAS,
} from '../utils/categorizacaoProdutos'

describe('getMacrocategoriaId', () => {
  it('classifica por palavra-chave do nome (sem acentos/caixa)', () => {
    expect(getMacrocategoriaId('BANANA')).toBe('frutas')
    expect(getMacrocategoriaId('Alface')).toBe('verduras')
    expect(getMacrocategoriaId('tomate')).toBe('legumes')
    expect(getMacrocategoriaId('BATATA')).toBe('tuberculos')
    expect(getMacrocategoriaId('FEIJÃO')).toBe('ovos_graos_diversos')
  })

  it('keyword do nome sobrescreve a categoria do banco (batata/cenoura são LEGUMES no banco)', () => {
    expect(getMacrocategoriaId('BATATA', 'LEGUMES')).toBe('tuberculos')
    expect(getMacrocategoriaId('CENOURA', 'LEGUMES')).toBe('tuberculos')
    expect(getMacrocategoriaId('TOMATE', 'FRUTAS')).toBe('legumes')
  })

  it('usa a categoria do banco como fallback quando o nome não resolve', () => {
    expect(getMacrocategoriaId('PRODUTO X', 'FRUTAS')).toBe('frutas')
    expect(getMacrocategoriaId('PRODUTO X', 'VERDURAS')).toBe('verduras')
    expect(getMacrocategoriaId('PRODUTO X', 'CEREAIS_GRAOS')).toBe('ovos_graos_diversos')
  })

  it('produto sem classificação óbvia cai em outros', () => {
    expect(getMacrocategoriaId('CARNE BOVINA')).toBe('outros')
    expect(getMacrocategoriaId('SERVICO LOGISTICA')).toBe('outros')
    expect(getMacrocategoriaId('', 'ALIMENTO_VAREJO')).toBe('outros')
  })

  it('casa por palavra inteira (cará ≠ carambola; milho verde ≠ milho)', () => {
    expect(getMacrocategoriaId('CARÁ')).toBe('tuberculos')
    expect(getMacrocategoriaId('CARAMBOLA')).toBe('frutas')
    expect(getMacrocategoriaId('MILHO VERDE')).toBe('legumes')
    expect(getMacrocategoriaId('MILHO')).toBe('ovos_graos_diversos')
    expect(getMacrocategoriaId('OVOS DE GALINHA', 'ALIMENTO_VAREJO')).toBe('ovos_graos_diversos')
    expect(getMacrocategoriaId('AÇAÍ', 'ALIMENTO_VAREJO')).toBe('frutas')
  })
})

describe('agruparPorMacrocategoria', () => {
  it('agrupa produtos em macrocategorias preservando o total', () => {
    const produtos = [
      { nome_produto: 'BANANA', categoria: 'FRUTAS' },
      { nome_produto: 'MACA', categoria: 'FRUTAS' },
      { nome_produto: 'ALFACE', categoria: 'VERDURAS' },
      { nome_produto: 'TOMATE', categoria: 'LEGUMES' },
      { nome_produto: 'BATATA', categoria: 'LEGUMES' },
      { nome_produto: 'FEIJAO', categoria: 'CEREAIS_GRAOS' },
      { nome_produto: 'CARNE BOVINA', categoria: 'PROTEINAS' },
    ]

    const grupos = agruparPorMacrocategoria(produtos)
    const porId = Object.fromEntries(grupos.map((g) => [g.id, g.itens.map((i) => i.nome_produto)]))

    expect(porId.frutas).toContain('BANANA')
    expect(porId.verduras).toContain('ALFACE')
    expect(porId.legumes).toContain('TOMATE')
    expect(porId.tuberculos).toContain('BATATA')
    expect(porId.ovos_graos_diversos).toContain('FEIJAO')
    expect(porId.outros).toContain('CARNE BOVINA')

    // Total preservado
    expect(grupos.reduce((soma, g) => soma + g.itens.length, 0)).toBe(produtos.length)
  })

  it('segue a ordem fixa das macrocategorias e omite grupos vazios', () => {
    const grupos = agruparPorMacrocategoria([{ produto: 'BANANA' }, { produto: 'CARNE' }])
    const ids = grupos.map((g) => g.id)
    // BANANA → frutas; CARNE → outros. Grupos intermediários vazios são omitidos,
    // mas a ordem relativa respeita MACROCATEGORIAS.
    expect(ids).toEqual(['frutas', 'outros'])
    expect(MACROCATEGORIAS[0].id).toBe('frutas')
  })

  it('aceita o campo produto (grade sazonal BR) além de nome_produto', () => {
    const grupos = agruparPorMacrocategoria([{ produto: 'ABACAXI' }])
    expect(grupos[0].id).toBe('frutas')
    expect(grupos[0].itens[0]).toMatchObject({ produto: 'ABACAXI' })
  })
})
