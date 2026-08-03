'use client'

import { CardContent } from './ui/card'
import { Badge } from './ui/badge'
import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'
import { CheckCircle2, MinusCircle, XCircle, Check } from 'lucide-react'
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

const STATUS_CONFIG: Record<
  string,
  {
    label: string
    icon: typeof CheckCircle2
    dotColor: string
    glowColor: string
    border: string
    bg: string
    text: string
  }
> = {
  VERDE: {
    label: 'Melhor Época!',
    icon: CheckCircle2,
    dotColor: '#16a34a',
    glowColor: '#16a34a',
    border: 'border-l-sazonal-verde-600 dark:border-l-sazonal-verde-400',
    bg: 'bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20',
    text: 'text-sazonal-verde-600 dark:text-sazonal-verde-400',
  },
  AMARELO: {
    label: 'Preço Normal',
    icon: MinusCircle,
    dotColor: '#ca8a04',
    glowColor: '#ca8a04',
    border: 'border-l-sazonal-amarelo-600 dark:border-l-sazonal-amarelo-400',
    bg: 'bg-sazonal-amarelo-50 dark:bg-sazonal-amarelo-dark/20',
    text: 'text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400',
  },
  VERMELHO: {
    label: 'Péssima Época',
    icon: XCircle,
    dotColor: '#dc2626',
    glowColor: '#dc2626',
    border: 'border-l-sazonal-vermelho-600 dark:border-l-sazonal-vermelho-400',
    bg: 'bg-sazonal-vermelho-50 dark:bg-sazonal-vermelho-dark/20',
    text: 'text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400',
  },
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

interface GameCardProps {
  product: ProdutoVarejo
  isSelected?: boolean
  onToggle?: () => void
}

export function GameCard({ product, isSelected, onToggle }: GameCardProps) {
  const config = STATUS_CONFIG[product.status_cor] ?? {
    label: 'Dados Insuficientes',
    icon: MinusCircle,
    dotColor: '#9ca3af',
    glowColor: '#9ca3af',
    border: 'border-l-gray-400',
    bg: 'bg-gray-50 dark:bg-gray-800',
    text: 'text-gray-500 dark:text-gray-400',
  }
  const emoji = getEmoji(product.nome_produto)
  const Icon = config.icon

  return (
    <motion.article
      initial={{ opacity: 0, scale: 0.9, y: 20 }}
      animate={{ opacity: 1, scale: 1, y: 0 }}
      transition={{ type: 'spring', stiffness: 400, damping: 25 }}
      whileHover={{
        scale: 1.02,
        boxShadow:
          '0 24px 48px -16px rgba(21,83,45,0.30), inset 0 -6px 12px rgba(21,83,45,0.12), inset 0 6px 12px rgba(255,255,255,0.45)',
      }}
      whileTap={{ scale: 0.98 }}
      className={cn(
        'min-w-[140px] cursor-pointer rounded-2xl border-l-4 transition-all duration-200',
        config.border,
        config.bg,
        'shadow-clay-card dark:shadow-clay-dark',
        isSelected && 'ring-sazonal-verde-500 ring-2 dark:ring-sazonal-verde-400',
        onToggle && 'hover:-translate-y-0.5',
      )}
      onClick={onToggle}
    >
      <CardContent className="relative flex flex-col items-center gap-1 p-3">
        {isSelected && onToggle && (
          <motion.div
            initial={{ scale: 0, rotate: -180 }}
            animate={{ scale: 1, rotate: 0 }}
            className="absolute right-2 top-2 flex h-5 w-5 items-center justify-center rounded-full bg-sazonal-verde-600 text-white"
            transition={{ type: 'spring', stiffness: 500, damping: 25 }}
          >
            <Check size={10} />
          </motion.div>
        )}
        <span className="text-[28px]" role="img" aria-label={product.nome_produto}>
          {emoji}
        </span>
        <p className="px-1 text-center text-sm font-bold leading-tight text-gray-900 dark:text-gray-100">
          {product.nome_produto}
        </p>
        <div className="flex flex-wrap items-center justify-center gap-1">
          <div className={cn('flex items-center gap-1 text-xs', config.text)}>
            <Icon size={14} />
            <span>{config.label}</span>
          </div>
          {product.is_forecast && (
            <motion.div
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              className="group relative"
            >
              <Badge variant="outline" className="cursor-default text-[10px]">
                📊 Estimativa
              </Badge>
              <motion.div
                initial={{ opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                className="absolute bottom-full left-1/2 z-50 mb-1 hidden -translate-x-1/2 group-hover:block"
                transition={{ duration: 0.15 }}
              >
                <div className="whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-xs text-white shadow-lg dark:bg-gray-100 dark:text-gray-900">
                  Dado estimado com base no histórico de 2024–2025. Confiança:{' '}
                  {product.confianca_baseline ?? '?'}%
                  <div className="absolute left-1/2 top-full -translate-x-1/2 border-4 border-transparent border-t-gray-900 dark:border-t-gray-100" />
                </div>
              </motion.div>
            </motion.div>
          )}
          {product.preco_estimado && (
            <motion.div
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              className="group relative"
            >
              <Badge
                variant="outline"
                className="cursor-default border-amber-300 text-[10px] text-amber-600 dark:border-amber-700 dark:text-amber-400"
              >
                🪄 Estimado
              </Badge>
              <motion.div
                initial={{ opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                className="absolute bottom-full left-1/2 z-50 mb-1 hidden -translate-x-1/2 group-hover:block"
                transition={{ duration: 0.15 }}
              >
                <div className="whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-xs text-white shadow-lg dark:bg-gray-100 dark:text-gray-900">
                  Preço estimado por inteligência artificial com base no histórico recente.
                  <div className="absolute left-1/2 top-full -translate-x-1/2 border-4 border-transparent border-t-gray-900 dark:border-t-gray-100" />
                </div>
              </motion.div>
            </motion.div>
          )}
        </div>
        {product.usou_fallback_12m && (
          <p className="mt-1 text-center text-[10px] text-gray-400 dark:text-gray-500">
            * Média 12 meses
          </p>
        )}
      </CardContent>
    </motion.article>
  )
}
