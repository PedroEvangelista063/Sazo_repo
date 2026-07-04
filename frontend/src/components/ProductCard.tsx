import { CheckCircle2, MinusCircle, XCircle, TrendingDown, TrendingUp, Equal, HelpCircle } from 'lucide-react'
import type { ProdutoVarejo, StatusOferta } from '../types/domain'

const PRODUTO_EMOJI: Record<string, string> = {
  ARROZ: '🍚', BANANA: '🍌', BATATA: '🥔', CAFE: '☕',
  CEBOLA: '🧅', CENOURA: '🥕', FEIJAO: '🫘', LARANJA: '🍊',
  LEITE: '🥛', MACA: '🍎', MANDIOCA: '🌿', MILHO: '🌽',
  OVO: '🥚', REPOLHO: '🥬', SOJA: '🫘', TOMATE: '🍅',
  UVA: '🍇', ALFACE: '🥬', BETERRABA: '🥗', PIMENTAO: '🫑',
  FRANGO: '🍗', CARNE: '🥩', QUEIJO: '🧀', IOGURTE: '🥛',
  OLEO: '🫒', ACUCAR: '🍚', FARINHA: '🌾', MACARRAO: '🍝',
}

type StatusConfig = {
  bg: string
  border: string
  text: string
  label: string
  icon: React.ReactNode
  imgClass: string
}

const OFERTA_MAP: Record<StatusOferta, StatusConfig> = {
  INSUFICIENTE: {
    bg: 'bg-gray-50 dark:bg-gray-800',
    border: 'border-gray-300 dark:border-gray-600',
    text: 'text-gray-500 dark:text-gray-400',
    label: 'Dados Insuficientes',
    icon: <HelpCircle className="h-5 w-5 text-gray-400 dark:text-gray-500" aria-hidden />,
    imgClass: 'opacity-60 grayscale-[30%]',
  },
  OFERTA: {
    bg: 'bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20',
    border: 'border-sazonal-verde-400 dark:border-sazonal-verde-dark',
    text: 'text-sazonal-verde-700 dark:text-sazonal-verde-400',
    label: 'Em Oferta!',
    icon: <TrendingDown className="h-5 w-5 text-sazonal-verde-600 dark:text-sazonal-verde-400" aria-hidden />,
    imgClass: 'opacity-100',
  },
  EQUILIBRADO: {
    bg: 'bg-sazonal-amarelo-50 dark:bg-sazonal-amarelo-dark/20',
    border: 'border-sazonal-amarelo-400 dark:border-sazonal-amarelo-dark',
    text: 'text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400',
    label: 'Preço Equilibrado',
    icon: <Equal className="h-5 w-5 text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400" aria-hidden />,
    imgClass: 'opacity-100',
  },
  ALTA: {
    bg: 'bg-sazonal-vermelho-50 dark:bg-sazonal-vermelho-dark/20',
    border: 'border-sazonal-vermelho-400 dark:border-sazonal-vermelho-dark',
    text: 'text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400',
    label: 'Pouca Oferta',
    icon: <TrendingUp className="h-5 w-5 text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400" aria-hidden />,
    imgClass: 'opacity-60 grayscale-[50%]',
  },
}

const STATUS_MAP: Record<string, StatusConfig> = {
  VERDE: {
    bg: 'bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20',
    border: 'border-sazonal-verde-400 dark:border-sazonal-verde-dark',
    text: 'text-sazonal-verde-700 dark:text-sazonal-verde-400',
    label: 'Melhor Época!',
    icon: <CheckCircle2 className="h-5 w-5 text-sazonal-verde-600 dark:text-sazonal-verde-400" aria-hidden />,
    imgClass: 'opacity-100',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-50 dark:bg-sazonal-amarelo-dark/20',
    border: 'border-sazonal-amarelo-400 dark:border-sazonal-amarelo-dark',
    text: 'text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400',
    label: 'Preço Normal',
    icon: <MinusCircle className="h-5 w-5 text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400" aria-hidden />,
    imgClass: 'opacity-100',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-50 dark:bg-sazonal-vermelho-dark/20',
    border: 'border-sazonal-vermelho-400 dark:border-sazonal-vermelho-dark',
    text: 'text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400',
    label: 'Péssima Época',
    icon: <XCircle className="h-5 w-5 text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400" aria-hidden />,
    imgClass: 'opacity-60 grayscale-[50%]',
  },
}

function getEmoji(name: string): string {
  const key = name
    .toUpperCase()
    .replace(/[^A-Z ]/g, '')
    .trim()
    .split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}

interface ProductCardProps {
  product: ProdutoVarejo
}

export function ProductCard({ product }: ProductCardProps) {
  const oferta = product.status_oferta
  const config = oferta
    ? OFERTA_MAP[oferta]
    : STATUS_MAP[product.status_cor]
  const emoji = getEmoji(product.nome_produto)

  return (
    <div
      className={`rounded-xl border-2 p-4 shadow-sm transition-shadow hover:shadow-md ${config.bg} ${config.border} dark:shadow-black/20`}
    >
      <div className="mb-3 flex justify-center">
        <div
          className={`flex h-20 w-20 items-center justify-center rounded-full bg-gray-100 text-3xl dark:bg-gray-800 ${config.imgClass}`}
          role="img"
          aria-label={product.nome_produto}
        >
          {emoji}
        </div>
        {product.preco_estimado && (
          <span
            className="absolute ml-16 mt-14 inline-flex items-center gap-1 rounded-full bg-purple-100 px-2 py-0.5 text-[10px] font-bold text-purple-700 dark:bg-purple-900/40 dark:text-purple-300"
            title="Preço estimado por inteligência artificial devido à falta de cotação oficial no período."
          >
            IA
          </span>
        )}
      </div>

      <h3 className={`mb-1 text-center text-sm font-semibold ${config.text}`}>
        {product.nome_produto}
      </h3>

      <div className={`flex items-center justify-center gap-1 text-xs font-medium ${config.text}`}>
        {config.icon}
        <span>{config.label}{product.usou_fallback_12m ? '*' : ''}</span>
      </div>

      {product.usou_fallback_12m && (
        <p className="mt-2 text-center text-[10px] leading-tight text-gray-400 dark:text-gray-500">
          * Comparação baseada na média dos últimos 12 meses (novo produto).
        </p>
      )}
      {product.preco_estimado && !product.usou_fallback_12m && (
        <p className="mt-2 text-center text-[10px] leading-tight text-gray-400 dark:text-gray-500">
          Preço estimado por inteligência artificial devido à falta de cotação oficial no período.
        </p>
      )}
    </div>
  )
}
