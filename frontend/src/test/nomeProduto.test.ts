import { describe, it, expect } from 'vitest'
import { limparNomeProduto } from '../utils/nomeProduto'

describe('limparNomeProduto — nome limpo do produto', () => {
  it('mantém nome simples sem sufixo', () => {
    expect(limparNomeProduto('TOMATE')).toBe('TOMATE')
    expect(limparNomeProduto('Carapau')).toBe('Carapau')
  })

  it('remove sufixo de tabela concatenado após |', () => {
    expect(limparNomeProduto('Maçã Gala | ALIMENTO_VAREJO')).toBe('Maçã Gala')
    expect(limparNomeProduto('Abacate|HORTIFRUTIGRANJEIROS')).toBe('Abacate')
  })

  it('remove sufixo de categoria ao final sem separador', () => {
    expect(limparNomeProduto('TOMATE ALIMENTO_VAREJO')).toBe('TOMATE')
    expect(limparNomeProduto('Sardinha pescados')).toBe('Sardinha')
  })

  it('colapsa múltiplos espaços internos', () => {
    expect(limparNomeProduto('Batata  Lisa')).toBe('Batata Lisa')
    expect(limparNomeProduto('  Cenoura  Extra a  ')).toBe('Cenoura Extra a')
  })

  it('retorna string vazia para null/undefined/vazio', () => {
    expect(limparNomeProduto(null)).toBe('')
    expect(limparNomeProduto(undefined)).toBe('')
    expect(limparNomeProduto('')).toBe('')
  })
})
