/**
 * Agrupamento semântico de produtos em macrocategorias culinárias.
 *
 * Modelo mental de corredores físicos do varejo: em vez de listas planas com
 * centenas de itens, agrupamos por categoria culinária (Frutas, Verduras,
 * Legumes, Tubérculos, Ovos/Grãos/Diversos) usando duas fontes de sinal:
 *
 * 1. **Nome do produto** (`nome_produto` ou `produto`) — palavras-chave
 *    normalizadas (minúsculas + sem acentos), com casamento por palavra
 *    inteira para evitar falsos positivos (ex.: "cará" ≠ "carambola").
 * 2. **Categoria do banco** (`categoria` / `categoria_final` da API) — usada
 *    como fallback quando o nome não resolve (ex.: FRUTAS, VERDURAS, LEGUMES).
 *
 * Produtos sem classificação óbvia caem em "Outros".
 */

export type MacrocategoriaId =
  'frutas' | 'verduras' | 'legumes' | 'tuberculos' | 'ovos_graos_diversos' | 'outros'

export interface MacrocategoriaDef {
  id: MacrocategoriaId
  nome: string
  emoji: string
  descricao: string
}

/** Ordem fixa de exibição (guarda-chuva de corredores). */
export const MACROCATEGORIAS: MacrocategoriaDef[] = [
  {
    id: 'frutas',
    nome: 'Frutas',
    emoji: '🍎',
    descricao: 'Frutas frescas in natura',
  },
  {
    id: 'verduras',
    nome: 'Verduras e Folhagens',
    emoji: '🥬',
    descricao: 'Folhas, talos e hortaliças',
  },
  {
    id: 'legumes',
    nome: 'Legumes',
    emoji: '🍆',
    descricao: 'Frutos e hortaliças de mesa',
  },
  {
    id: 'tuberculos',
    nome: 'Tubérculos e Raízes',
    emoji: '🥔',
    descricao: 'Raízes, tubérculos e bulbos',
  },
  {
    id: 'ovos_graos_diversos',
    nome: 'Ovos, Grãos e Diversos',
    emoji: '🥚',
    descricao: 'Ovos, cereais, grãos e outros',
  },
  {
    id: 'outros',
    nome: 'Outros',
    emoji: '📦',
    descricao: 'Sem classificação direta',
  },
]

export interface ProdutoCategoriavel {
  /** Campo usado pela API de produtos/cards. */
  nome_produto?: string
  /** Campo usado pela grade sazonal nacional (BR). */
  produto?: string
  /** Categoria do banco (categoria_final): FRUTAS, LEGUMES, VERDURAS... */
  categoria?: string | null
}

export interface MacrocategoriaGrupo<T extends ProdutoCategoriavel> extends MacrocategoriaDef {
  itens: T[]
}

/** Normaliza: minúsculas + sem acentos + colapsa espaços. */
function normalizar(nome: string): string {
  return nome
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Remove o 's' final de plurais comuns (ovos → ovo, bananas → banana). */
function singularizar(palavra: string): string {
  if (palavra.length > 3 && palavra.endsWith('s')) return palavra.slice(0, -1)
  return palavra
}

/** Normaliza uma palavra/frase para chave de comparação (singular). */
function chave(palavra: string): string {
  return palavra
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .map(singularizar)
    .join(' ')
}

/**
 * Casa uma palavra inteira (ou frase) dentro do nome normalizado.
 *
 * Tanto o nome quanto a keyword são singularizados, então "OVOS DE GALINHA"
 * casa com a keyword "ovo" e "CARAMBOLA" NÃO casa com "cará" (palavra
 * inteira, sem falsos positivos de substring).
 */
function contemPalavra(nome: string, palavra: string): boolean {
  const alvo = ` ${chave(palavra)} `
  return ` ${chave(nome)} `.includes(alvo)
}

// Palavras-chave por macrocategoria (já normalizadas).
const KEYWORDS: Record<Exclude<MacrocategoriaId, 'outros'>, string[]> = {
  frutas: [
    'banana',
    'maca',
    'laranja',
    'tangerina',
    'mexerica',
    'mamao',
    'uva',
    'melancia',
    'melao',
    'abacaxi',
    'manga',
    'goiaba',
    'maracuja',
    'limao',
    'pera',
    'pesego',
    'morango',
    'kiwi',
    'caju',
    'acerola',
    'abacate',
    'coco',
    'caqui',
    'figo',
    'ameixa',
    'jaca',
    'graviola',
    'carambola',
    'pitanga',
    'jabuticaba',
    'lichia',
    'pinha',
    'framboesa',
    'amora',
    'cereja',
    'nespera',
    'acai',
    'jambo',
    'cupuacu',
    'bacuri',
    'sapoti',
    'jenipapo',
    'mangaba',
    'umbu',
    'murici',
    'fruta',
  ],
  verduras: [
    'alface',
    'couve',
    'espinafre',
    'rucula',
    'agriao',
    'brocolis',
    'couve-flor',
    'couve flor',
    'repolho',
    'acelga',
    'chicoria',
    'almeirao',
    'coentro',
    'salsinha',
    'salsa',
    'cebolinha',
    'manjericao',
    'hortela',
    'taioba',
    'bertalha',
    'escarola',
    'mostarda',
    'alho-poro',
    'alho poro',
    'verdura',
    'folha',
  ],
  legumes: [
    'tomate',
    'pimentao',
    'pimenta',
    'abobrinha',
    'abobora',
    'berinjela',
    'pepino',
    'quiabo',
    'jilo',
    'chuchu',
    'vagem',
    'maxixe',
    'milho verde',
    'milho-verde',
    'ervilha',
    'cebola',
    'alho',
    'legume',
  ],
  tuberculos: [
    'batata',
    'mandioca',
    'aipim',
    'macaxeira',
    'inhame',
    'cara',
    'cenoura',
    'beterraba',
    'rabanete',
    'nabo',
    'mandioquinha',
    'baroa',
    'tuberculo',
    'raiz',
  ],
  ovos_graos_diversos: [
    'ovo',
    'ovos',
    'feijao',
    'feijoes',
    'arroz',
    'grao',
    'graos',
    'soja',
    'lentilha',
    'amendoim',
    'castanha',
    'noz',
    'aveia',
    'trigo',
    'farinha',
    'milho',
    'oleo',
    'acucar',
    'cafe',
    'mel',
    'pinhao',
    'queijo',
    'leite',
    'fuba',
    'polenta',
    'gergelim',
    'linhaca',
    'chia',
    'quinoa',
    'cereal',
  ],
}

/** Ordem de avaliação (resolver antes os termos mais específicos). */
const ORDEM_AVALIACAO: Exclude<MacrocategoriaId, 'outros'>[] = [
  'frutas',
  'verduras',
  'legumes',
  'tuberculos',
  'ovos_graos_diversos',
]

/** Categoria do banco → macrocategoria (fallback). */
const CATEGORIA_MAP: Record<string, MacrocategoriaId> = {
  FRUTAS: 'frutas',
  VERDURAS: 'verduras',
  LEGUMES: 'legumes',
  CEREAIS_GRAOS: 'ovos_graos_diversos',
}

/** Classifica um produto pela macrocategoria (nome → keywords → categoria → Outros). */
export function getMacrocategoriaId(nome: string, categoria?: string | null): MacrocategoriaId {
  const n = normalizar(nome)

  for (const id of ORDEM_AVALIACAO) {
    if (KEYWORDS[id].some((kw) => contemPalavra(n, kw))) return id
  }

  const cat = categoria?.trim().toUpperCase() ?? ''
  if (cat && CATEGORIA_MAP[cat]) return CATEGORIA_MAP[cat]

  return 'outros'
}

/** Agrupa produtos em macrocategorias (ordem fixa; grupos vazios são omitidos). */
export function agruparPorMacrocategoria<T extends ProdutoCategoriavel>(
  produtos: T[],
): MacrocategoriaGrupo<T>[] {
  const porId = new Map<MacrocategoriaId, T[]>()
  for (const def of MACROCATEGORIAS) porId.set(def.id, [])

  for (const p of produtos) {
    const nome = p.nome_produto ?? p.produto ?? ''
    const id = getMacrocategoriaId(nome, p.categoria)
    porId.get(id)?.push(p)
  }

  return MACROCATEGORIAS.map((def) => ({
    ...def,
    itens: porId.get(def.id) ?? [],
  })).filter((g) => g.itens.length > 0)
}
