import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'
import { Check } from 'lucide-react'
import type { ProdutoVarejo } from '../types/domain'

const PRODUTO_EMOJI: Record<string, string> = {
  ARROZ: '🍚',
  BANANA: '🍌',
  BATATA: '🥔',
  CAFE: '☕',
  CEBOLA: '🧅',
  CENOURA: '🥕',
  FEIJAO: '🫘',
  LARANJA: '🍊',
  LEITE: '🥛',
  MACA: '🍎',
  MANDIOCA: '🌿',
  MILHO: '🌽',
  OVO: '🥚',
  REPOLHO: '🥬',
  SOJA: '🫘',
  TOMATE: '🍅',
  UVA: '🍇',
  ALFACE: '🥬',
  BETERRABA: '🥗',
  PIMENTAO: '🫑',
  FRANGO: '🍗',
  CARNE: '🥩',
  QUEIJO: '🧀',
  IOGURTE: '🥛',
  OLEO: '🫒',
  ACUCAR: '🍚',
  FARINHA: '🌾',
  MACARRAO: '🍝',
}

function getEmoji(name: string): string {
  const key =
    name
      .toUpperCase()
      .replace(/[^A-Z ]/g, '')
      .trim()
      .split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}

interface ProductCardProps {
  product: ProdutoVarejo
  isSelected?: boolean
  onToggle?: () => void
  origemUf?: string | null
}

export function ProductCard({ product, isSelected, onToggle }: ProductCardProps) {
  const emoji = getEmoji(product.nome_produto)

  const statusColors: Record<string, string> = {
    VERDE: 'bg-status-green text-on-primary shadow-clay-green border border-status-green/50',
    AMARELO:
      'bg-status-yellow text-on-secondary-container shadow-clay-pressed border border-status-yellow/50',
    VERMELHO: 'bg-status-red text-on-error shadow-clay-pressed border border-status-red/50',
  }

  const defaultColor =
    'bg-surface-container-low text-on-surface-variant shadow-clay-dark border border-outline-variant/30'

  const colorClass = statusColors[product.status_cor] || defaultColor

  return (
    <motion.div
      onClick={onToggle}
      whileHover={{ y: -4, scale: 1.02 }}
      whileTap={{ scale: 0.95 }}
      transition={{ duration: 0.2 }}
      className={cn(
        'clay-card group relative flex cursor-pointer flex-col items-center justify-center p-md',
        isSelected ? 'bg-primary/5 ring-2 ring-primary' : '',
      )}
    >
      {isSelected && onToggle && (
        <div className="absolute right-2 top-2 flex h-5 w-5 items-center justify-center rounded-full bg-primary shadow-md">
          <Check className="h-3 w-3 text-on-primary" />
        </div>
      )}

      {/* Sazonalidade representada como o círculo de cor em formato claymorphism */}
      <div
        className={cn(
          'mb-3 flex h-14 w-14 items-center justify-center rounded-full text-3xl transition-transform group-hover:scale-110',
          colorClass,
        )}
      >
        {emoji}
      </div>

      <p className="font-display line-clamp-2 text-center text-sm font-bold leading-tight text-on-surface">
        {product.nome_produto}
      </p>
    </motion.div>
  )
}
