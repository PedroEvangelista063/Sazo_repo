import { memo } from 'react'
import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'
import { Check } from 'lucide-react'
import { limparNomeProduto } from '@/utils/nomeProduto'
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

/**
 * Semáforo linguístico: badge de TEXTO acoplado à cor (daltonismo + cognição).
 *
 * Fallback de segurança: qualquer `status_cor` fora de VERDE/AMARELO/VERMELHO
 * (ou nulo/desconhecido) é tratado como AMARELO ("Estável — Preço Normal"),
 * a opção mais neutra — NUNCA há estado vazio nem cor cinza.
 */
const STATUS_BADGES: Record<string, { label: string; badgeClass: string; circleClass: string }> = {
  VERDE: {
    label: '🟢 Época Boa — Barato',
    badgeClass: 'bg-status-green text-white border border-status-green/50',
    circleClass: 'bg-status-green text-on-primary shadow-clay-green border border-status-green/50',
  },
  AMARELO: {
    label: '🟡 Estável — Preço Normal',
    badgeClass: 'bg-status-yellow text-on-secondary-container border border-status-yellow/50',
    circleClass:
      'bg-status-yellow text-on-secondary-container shadow-clay-pressed border border-status-yellow/50',
  },
  VERMELHO: {
    label: '🔴 Época Ruim — Caro',
    badgeClass: 'bg-status-red text-white border border-status-red/50',
    circleClass: 'bg-status-red text-on-error shadow-clay-pressed border border-status-red/50',
  },
}

/**
 * Detecta dado projetado (Deep Fallback / forecast) usando os campos reais
 * que o hook recebe da API (`is_forecast`, `tipo_dado`, `mensagem_transparencia`).
 */
function isDadoProjetado(p: ProdutoVarejo): boolean {
  if (p.is_forecast) return true
  const tipo = (p.tipo_dado ?? '').toUpperCase()
  if (tipo.includes('FALLBACK') || tipo.includes('PROJEC') || tipo.includes('FORECAST')) return true
  if (
    p.mensagem_transparencia &&
    /proje[cç]|projetado|anos anteriores|fallback/i.test(p.mensagem_transparencia)
  ) {
    return true
  }
  return false
}

interface ProductCardProps {
  product: ProdutoVarejo
  isSelected?: boolean
  onToggle?: (nomeProduto: string) => void
  origemUf?: string | null
}

function ProductCardInner({ product, isSelected, onToggle }: ProductCardProps) {
  const nomeLimpo = limparNomeProduto(product.nome_produto)
  const emoji = getEmoji(nomeLimpo)
  const badge = STATUS_BADGES[product.status_cor] ?? STATUS_BADGES.AMARELO
  const projetado = isDadoProjetado(product)
  const mensagemProjecao =
    product.mensagem_transparencia?.trim() || 'Projeção baseada em anos anteriores'

  return (
    <motion.div
      onClick={() => onToggle?.(product.nome_produto)}
      whileHover={{ y: -2 }}
      whileTap={{ y: 1 }}
      transition={{ duration: 0.2 }}
      className={cn(
        'relative flex min-h-[204px] cursor-pointer flex-col items-center justify-center gap-2 rounded-3xl p-4 text-center',
        'bg-clay-surface shadow-clay-rest transition-all duration-150 active:scale-95',
        'dark:bg-surface-container-low dark:shadow-clay-dark',
        isSelected ? 'ring-2 ring-primary' : '',
      )}
    >
      {isSelected && onToggle && (
        <div className="absolute right-2 top-2 flex h-5 w-5 items-center justify-center rounded-full bg-primary shadow-md">
          <Check className="h-3 w-3 text-on-primary" />
        </div>
      )}

      {/* Badge de semáforo linguístico (texto + cor) */}
      <span
        className={cn(
          'inline-flex max-w-full items-center rounded-full px-2.5 py-1 text-xs font-bold leading-tight',
          badge.badgeClass,
        )}
      >
        {badge.label}
      </span>

      {/* Círculo de cor em formato claymorphism */}
      <div
        className={cn(
          'flex h-12 w-12 items-center justify-center rounded-full text-2xl transition-transform',
          badge.circleClass,
        )}
      >
        {emoji}
      </div>

      <p className="font-display line-clamp-2 text-lg font-bold leading-tight text-on-surface">
        {nomeLimpo}
      </p>

      {projetado && (
        <p
          className="line-clamp-2 text-xs text-on-surface-variant opacity-70"
          title={mensagemProjecao}
        >
          {mensagemProjecao}
        </p>
      )}
    </motion.div>
  )
}

/** Memoizado para evitar re-render de centenas de cards ao digitar na busca. */
export const ProductCard = memo(ProductCardInner)
