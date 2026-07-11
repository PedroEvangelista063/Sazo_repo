import { Card, CardContent } from './ui/card'
import { Badge } from './ui/badge'
import { cn } from '@/lib/utils'
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

const STATUS_CONFIG: Record<string, { label: string; icon: typeof CheckCircle2; border: string; bg: string; text: string }> = {
  VERDE: {
    label: 'Melhor Época!',
    icon: CheckCircle2,
    border: 'border-l-sazonal-verde-600 dark:border-l-sazonal-verde-400',
    bg: 'bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20',
    text: 'text-sazonal-verde-600 dark:text-sazonal-verde-400',
  },
  AMARELO: {
    label: 'Preço Normal',
    icon: MinusCircle,
    border: 'border-l-sazonal-amarelo-600 dark:border-l-sazonal-amarelo-dark',
    bg: 'bg-sazonal-amarelo-50 dark:bg-sazonal-amarelo-dark/20',
    text: 'text-sazonal-amarelo-600 dark:text-sazonal-amarelo-dark',
  },
  VERMELHO: {
    label: 'Péssima Época',
    icon: XCircle,
    border: 'border-l-sazonal-vermelho-600 dark:border-l-sazonal-vermelho-dark',
    bg: 'bg-sazonal-vermelho-50 dark:bg-sazonal-vermelho-dark/20',
    text: 'text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400',
  },
}

function getEmoji(name: string): string {
  const key = name.toUpperCase().replace(/[^A-Z ]/g, '').trim().split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}

interface ProductCardProps {
  product: ProdutoVarejo
}

export function ProductCard({ product }: ProductCardProps) {
  const config = STATUS_CONFIG[product.status_cor] ?? {
    label: 'Dados Insuficientes',
    icon: MinusCircle,
    border: 'border-l-gray-400',
    bg: 'bg-gray-50 dark:bg-gray-800',
    text: 'text-gray-500 dark:text-gray-400',
  }
  const emoji = getEmoji(product.nome_produto)
  const Icon = config.icon

  return (
    <Card
      className={cn(
        'border-l-4 min-w-[140px]',
        config.border,
        config.bg,
      )}
    >
      <CardContent className="flex flex-col items-center gap-1 p-3">
        <span className="text-[28px]" role="img" aria-label={product.nome_produto}>
          {emoji}
        </span>
        <p className="text-sm font-bold text-center leading-tight text-gray-900 dark:text-gray-100">
          {product.nome_produto}
        </p>
        <div className="flex items-center gap-1 flex-wrap justify-center">
          <div className={cn('flex items-center gap-1 text-xs', config.text)}>
            <Icon size={14} />
            <span>{config.label}</span>
          </div>
          {product.is_forecast && (
            <div className="relative group">
              <Badge variant="outline" className="text-[10px] cursor-default">
                📊 Estimativa
              </Badge>
              <div className="absolute bottom-full mb-1 left-1/2 -translate-x-1/2 hidden group-hover:block z-50">
                <div className="bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-xs rounded px-2 py-1 whitespace-nowrap shadow-lg">
                  Dado estimado com base no histórico de 2024–2025.
                  Confiança: {product.confianca_baseline ?? '?'}%
                  <div className="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-gray-900 dark:border-t-gray-100" />
                </div>
              </div>
            </div>
          )}
        </div>
        {product.usou_fallback_12m && (
          <p className="text-[10px] text-center text-gray-400 dark:text-gray-500">
            * Média 12 meses
          </p>
        )}
      </CardContent>
    </Card>
  )
}
