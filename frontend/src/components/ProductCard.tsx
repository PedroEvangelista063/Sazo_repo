import { useState } from 'react'
import { CheckCircle2, MinusCircle, XCircle } from 'lucide-react'
import type { ProdutoVarejo } from '../types/domain'

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

const STATUS_MAP: Record<string, StatusConfig> = {
  VERDE: {
    bg: 'bg-sazonal-verde-50',
    border: 'border-sazonal-verde-400',
    text: 'text-sazonal-verde-700',
    label: 'Melhor Época!',
    icon: <CheckCircle2 className="h-5 w-5 text-sazonal-verde-600" aria-hidden />,
    imgClass: 'opacity-100',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-50',
    border: 'border-sazonal-amarelo-400',
    text: 'text-sazonal-amarelo-600',
    label: 'Preço Normal',
    icon: <MinusCircle className="h-5 w-5 text-sazonal-amarelo-600" aria-hidden />,
    imgClass: 'opacity-100',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-50',
    border: 'border-sazonal-vermelho-400',
    text: 'text-sazonal-vermelho-600',
    label: 'Péssima Época',
    icon: <XCircle className="h-5 w-5 text-sazonal-vermelho-600" aria-hidden />,
    imgClass: 'opacity-60 grayscale-[50%]',
  },
  INSUFICIENTE: {
    bg: 'bg-gray-50',
    border: 'border-gray-300',
    text: 'text-gray-500',
    label: 'Dados Insuficientes',
    icon: <MinusCircle className="h-5 w-5 text-gray-400" aria-hidden />,
    imgClass: 'opacity-80',
  },
}

function slugify(name: string): string {
  return name
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
}

function getCdnUrl(name: string): string {
  const slug = slugify(name)
  return `https://cdn.querocomprar.com/produtos/alimento_varejo/${slug}.webp`
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
  const [imgFailed, setImgFailed] = useState(false)
  const config = STATUS_MAP[product.status_cor] ?? STATUS_MAP.INSUFICIENTE
  const emoji = getEmoji(product.nome_produto)

  return (
    <div
      className={`rounded-xl border-2 p-4 shadow-sm transition-shadow hover:shadow-md ${config.bg} ${config.border}`}
    >
      <div className="mb-3 flex justify-center">
        {imgFailed ? (
          <div
            className={`flex h-20 w-20 items-center justify-center rounded-full bg-gray-100 text-3xl ${config.imgClass}`}
            role="img"
            aria-label={product.nome_produto}
          >
            {emoji}
          </div>
        ) : (
          <img
            src={getCdnUrl(product.nome_produto)}
            alt={product.nome_produto}
            className={`h-20 w-20 rounded-full object-cover ${config.imgClass}`}
            loading="lazy"
            onError={() => setImgFailed(true)}
          />
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
        <p className="mt-2 text-center text-[10px] leading-tight text-gray-400">
          * Comparação baseada na média dos últimos 12 meses (novo produto).
        </p>
      )}
    </div>
  )
}
