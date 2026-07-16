import { motion } from 'framer-motion'
import { Badge } from './ui/badge'
import { cn } from '@/lib/utils'
import SpotlightCard from '@/components/SpotlightCard'
import { CheckCircle2, MinusCircle, XCircle, Check, Truck } from 'lucide-react'
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

const STATUS_CONFIG: Record<string, { label: string; icon: typeof CheckCircle2; cor: string; corBg: string }> = {
  VERDE: {
    label: 'Melhor Época!',
    icon: CheckCircle2,
    cor: '#16a34a',
    corBg: 'rgba(22,163,74,0.08)',
  },
  AMARELO: {
    label: 'Preço Normal',
    icon: MinusCircle,
    cor: '#ca8a04',
    corBg: 'rgba(202,138,4,0.08)',
  },
  VERMELHO: {
    label: 'Péssima Época',
    icon: XCircle,
    cor: '#dc2626',
    corBg: 'rgba(220,38,38,0.08)',
  },
}

function getEmoji(name: string): string {
  const key = name.toUpperCase().replace(/[^A-Z ]/g, '').trim().split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}

interface ProductCardProps {
  product: ProdutoVarejo
  isSelected?: boolean
  onToggle?: () => void
  origemUf?: string | null
}

export function ProductCard({ product, isSelected, onToggle, origemUf }: ProductCardProps) {
  const config = STATUS_CONFIG[product.status_cor] ?? {
    label: 'Dados Insuficientes',
    icon: MinusCircle,
    cor: '#9ca3af',
    corBg: 'rgba(156,163,175,0.08)' as const,
  } as (typeof STATUS_CONFIG)[string]
  const emoji = getEmoji(product.nome_produto)
  const Icon = config.icon

  return (
    <motion.div
      onClick={onToggle}
      whileHover={{ y: -4, scale: 1.02 }}
      whileTap={{ scale: 0.98 }}
      transition={{ duration: 0.2 }}
    >
      <SpotlightCard
        spotlightColor={config.corBg as `rgba(${number}, ${number}, ${number}, ${number})`}
        className={cn(
          'border rounded-xl cursor-pointer transition-shadow duration-200 overflow-hidden',
          isSelected
            ? 'border-gray-300 dark:border-gray-600 shadow-xl'
            : 'border-gray-200 dark:border-gray-700 shadow-sm hover:shadow-lg',
          onToggle ? 'cursor-pointer' : 'cursor-default',
        )}
      >
        <div className="relative p-3 flex flex-col items-center gap-1">
          {isSelected && onToggle && (
            <div className="absolute top-1.5 right-1.5 w-5 h-5 rounded-full bg-sazonal-verde-600 flex items-center justify-center shadow-md">
              <Check className="w-3.5 h-3.5 text-white" />
            </div>
          )}

          <span
            className="text-[28px] leading-none"
            role="img"
            aria-label={product.nome_produto}
          >
            {emoji}
          </span>

          <p className="text-sm font-bold text-center leading-tight text-gray-900 dark:text-gray-100 mt-0.5">
            {product.nome_produto}
          </p>

          <div className="flex items-center gap-1 text-xs mt-0.5" style={{ color: config.cor }}>
            <Icon size={14} />
            <span>{config.label}</span>
          </div>

          <div className="flex flex-wrap items-center justify-center gap-1 mt-1">
            {product.is_forecast && (
              <div className="relative group">
                <Badge variant="outline" className="text-[10px] cursor-default shadow-sm">
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
            {product.preco_estimado && (
              <div className="relative group">
                <Badge variant="outline" className="text-[10px] cursor-default text-amber-600 border-amber-300 dark:text-amber-400 dark:border-amber-700 shadow-sm">
                  🪄 Estimado
                </Badge>
                <div className="absolute bottom-full mb-1 left-1/2 -translate-x-1/2 hidden group-hover:block z-50">
                  <div className="bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-xs rounded px-2 py-1 whitespace-nowrap shadow-lg">
                    Preço estimado por inteligência artificial com base no histórico recente.
                    <div className="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-gray-900 dark:border-t-gray-100" />
                  </div>
                </div>
              </div>
            )}
          </div>

          {product.usou_fallback_12m && (
            <p className="text-[10px] text-center text-gray-400 dark:text-gray-500 mt-0.5">
              * Média 12 meses
            </p>
          )}

          {origemUf && (
            <div className="flex items-center gap-1 mt-1 text-[9px] text-gray-400 dark:text-gray-500">
              <Truck size={9} />
              <span>Origem: {origemUf}</span>
            </div>
          )}
        </div>
      </SpotlightCard>
    </motion.div>
  )
}
