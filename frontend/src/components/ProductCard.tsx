import { useState } from 'react'
import { CheckCircle2, AlertTriangle, XCircle } from 'lucide-react'
import type { ProductSeasonality } from '../types'
import { getProdutoEmoji } from '../types'

type StatusConfig = {
  bg: string
  border: string
  text: string
  label: string
  icon: React.ReactNode
  opacity: string
}

const STATUS_MAP: Record<string, StatusConfig> = {
  VERDE: {
    bg: 'bg-sazonal-verde-50',
    border: 'border-sazonal-verde-400',
    text: 'text-sazonal-verde-700',
    label: 'Melhor Época!',
    icon: <CheckCircle2 className="h-5 w-5 text-sazonal-verde-600" aria-hidden />,
    opacity: 'opacity-100',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-50',
    border: 'border-sazonal-amarelo-400',
    text: 'text-sazonal-amarelo-600',
    label: 'Preço Normal',
    icon: <AlertTriangle className="h-5 w-5 text-sazonal-amarelo-600" aria-hidden />,
    opacity: 'opacity-100',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-50',
    border: 'border-sazonal-vermelho-400',
    text: 'text-sazonal-vermelho-600',
    label: 'Péssima Época',
    icon: <XCircle className="h-5 w-5 text-sazonal-vermelho-600" aria-hidden />,
    opacity: 'opacity-60',
  },
  INSUFICIENTE: {
    bg: 'bg-gray-50',
    border: 'border-gray-300',
    text: 'text-gray-500',
    label: 'Dados Insuficientes',
    icon: null,
    opacity: 'opacity-80',
  },
}

function getProductImageUrl(id: number): string {
  return `https://cdn.querocomprar.com/produtos/${id}.webp`
}

export function ProductCardSkeleton() {
  return (
    <div className="animate-pulse-soft rounded-xl border-2 border-gray-200 bg-white p-4 shadow-sm">
      <div className="mx-auto mb-3 h-20 w-20 rounded-full bg-gray-200" />
      <div className="mx-auto mb-2 h-4 w-24 rounded bg-gray-200" />
      <div className="mx-auto h-3 w-32 rounded bg-gray-200" />
    </div>
  )
}

interface ProductCardProps {
  product: ProductSeasonality
}

export function ProductCard({ product }: ProductCardProps) {
  const [imgFailed, setImgFailed] = useState(false)
  const config = STATUS_MAP[product.status_cor] ?? STATUS_MAP.INSUFICIENTE
  const emoji = getProdutoEmoji(product.nome_produto)

  return (
    <div
      className={`rounded-xl border-2 p-4 shadow-sm transition-shadow hover:shadow-md ${config.bg} ${config.border} ${config.opacity}`}
    >
      <div className="mb-3 flex justify-center">
        {imgFailed ? (
          <div className="flex h-20 w-20 items-center justify-center rounded-full bg-gray-100 text-3xl">
            <span role="img" aria-label={product.nome_produto}>{emoji}</span>
          </div>
        ) : (
          <img
            src={getProductImageUrl(product.id_produto)}
            alt={product.nome_produto}
            className="h-20 w-20 rounded-full object-cover"
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
        <span>{config.label}</span>
      </div>
    </div>
  )
}
