/**
 * Formatador de nome de produto para exibição (camada de apresentação).
 *
 * O nome exibido ao usuário deve ser APENAS o nome do produto — sem o nome da
 * lista/tabela/categoria à frente (ex: "Maçã Gala | ALIMENTO_VAREJO"). A API
 * hoje entrega `produto` limpo e `categoria` em campo separado, mas o
 * formatador é defensivo para qualquer fonte que concatene o sufixo.
 *
 * Regra exata:
 *  1. trims espaços nas bordas;
 *  2. corta no primeiro '|' (separador clássico de tabela) — mantém a parte
 *     do nome;
 *  3. remove sufixo de categoria conhecido ao final (ALIMENTO_VAREJO,
 *     HORTIFRUTIGRANJEIROS, PESCADOS), case-insensitive;
 *  4. colapsa múltiplos espaços internos (dado real: "Batata  Lisa").
 */

const SUFIXOS_CATEGORIA: readonly string[] = ['ALIMENTO_VAREJO', 'HORTIFRUTIGRANJEIROS', 'PESCADOS']

export function limparNomeProduto(nome: string | null | undefined): string {
  if (!nome) return ''

  let limpo = nome.trim()

  const idxPipe = limpo.indexOf('|')
  if (idxPipe !== -1) limpo = limpo.slice(0, idxPipe)

  for (const suf of SUFIXOS_CATEGORIA) {
    const re = new RegExp(`\\s+${suf}$`, 'i')
    limpo = limpo.replace(re, '')
  }

  return limpo.replace(/\s+/g, ' ').trim()
}
