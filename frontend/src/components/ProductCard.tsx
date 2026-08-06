import { motion } from 'framer-motion'
import { Badge } from './ui/badge'
import { cn } from '@/lib/utils'
import SpotlightCard from '@/components/SpotlightCard'
import { DataTransparencyInfo } from '@/components/DataTransparencyInfo'
import { CheckCircle2, MinusCircle, XCircle, Check, Truck } from 'lucide-react'
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
  { label: string; icon: typeof CheckCircle2; cor: string; corBg: string }
> = {
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
  const key =
    name
      .toUpperCase()
      .replace(/[^A-Z ]/g, '')
      .trim()
      .split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}

function tipoDadoLabel(
  tipo: string | null | undefined,
  ano: number | null | undefined,
): string | null {
  if (!tipo) return null
  if (tipo === 'REAL_ATUAL') return 'Coleta Efetiva'
  if (tipo === 'HISTORICO_BASE') {
    return ano != null ? `Histórico Real '${String(ano).slice(2)}` : 'Histórico Real'
  }
  return 'Referência'
}

function tipoDadoVariant(tipo: string | null | undefined): 'outline' | 'default' | 'warning' {
  if (tipo === 'REAL_ATUAL') return 'default'
  if (tipo === 'HISTORICO_BASE') return 'warning'
  return 'outline'
}

interface ProductCardProps {
  product: ProdutoVarejo
  isSelected?: boolean
  onToggle?: () => void
  origemUf?: string | null
}

export function ProductCard({ product, isSelected, onToggle, origemUf }: ProductCardProps) {
  const config =
    STATUS_CONFIG[product.status_cor] ??
    ({
      label: 'Dados Insuficientes',
      icon: MinusCircle,
      cor: '#9ca3af',
      corBg: 'rgba(156,163,175,0.08)' as const,
    } as (typeof STATUS_CONFIG)[string])
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
          'cursor-pointer overflow-hidden rounded-3xl border transition-shadow duration-200',
          isSelected
            ? 'border-gray-300 shadow-[0_22px_44px_-14px_rgba(21,83,45,0.35),inset_0_-6px_12px_rgba(0,0,0,0.35),inset_0_6px_12px_rgba(255,255,255,0.10)] dark:border-gray-600 dark:shadow-clay-dark-hover'
            : 'border-gray-200 shadow-[0_18px_36px_-12px_rgba(21,83,45,0.28),inset_0_-6px_12px_rgba(0,0,0,0.35),inset_0_6px_12px_rgba(255,255,255,0.10)] hover:shadow-[0_28px_52px_-14px_rgba(21,83,45,0.35),inset_0_-6px_12px_rgba(0,0,0,0.35),inset_0_6px_12px_rgba(255,255,255,0.12)] dark:border-gray-700 dark:shadow-clay-dark',
          onToggle ? 'cursor-pointer' : 'cursor-default',
        )}
      >
        <div className="relative flex flex-col items-center gap-1 p-3">
          {isSelected && onToggle && (
            <div className="absolute right-1.5 top-1.5 flex h-5 w-5 items-center justify-center rounded-full bg-sazonal-verde-600 shadow-md">
              <Check className="h-3.5 w-3.5 text-white" />
            </div>
          )}

          <span className="text-[28px] leading-none" role="img" aria-label={product.nome_produto}>
            {emoji}
          </span>

          <p className="mt-0.5 text-center font-display text-sm font-bold leading-tight text-gray-900 dark:text-gray-100">
            {product.nome_produto}
          </p>

          <div className="mt-0.5 flex items-center gap-1 text-xs" style={{ color: config.cor }}>
            <Icon size={14} />
            <span>{config.label}</span>
          </div>

          <div className="mt-1 flex flex-wrap items-center justify-center gap-1">
            {tipoDadoLabel(product.tipo_dado, product.ano_referencia) && (
              <Badge
                variant={tipoDadoVariant(product.tipo_dado)}
                className="cursor-default text-[10px] shadow-sm"
              >
                {tipoDadoLabel(product.tipo_dado, product.ano_referencia)}
              </Badge>
            )}
            <DataTransparencyInfo
              tipo_dado={product.tipo_dado}
              ano_referencia={product.ano_referencia}
              mensagem_transparencia={product.mensagem_transparencia}
              is_dado_legado={product.is_dado_legado}
              size={12}
            />
          </div>

          {(product.ano_referencia != null || product.tipo_dado) && (
            <p className="mt-0.5 text-center text-[10px] text-gray-400 dark:text-gray-500">
              Ano de apuração: {product.ano_referencia ?? '—'}
            </p>
          )}

          {product.usou_fallback_12m && (
            <p className="mt-0.5 text-center text-[10px] text-gray-400 dark:text-gray-500">
              * Média 12 meses
            </p>
          )}

          {origemUf && (
            <div className="mt-1 flex items-center gap-1 text-[9px] text-gray-400 dark:text-gray-500">
              <Truck size={9} />
              <span>Origem: {origemUf}</span>
            </div>
          )}
        </div>
      </SpotlightCard>
    </motion.div>
  )
}
