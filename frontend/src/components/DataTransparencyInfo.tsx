import { Info } from 'lucide-react'
import { Badge } from './ui/badge'
import { cn } from '@/lib/utils'

export interface DataTransparencyInfoProps {
  /** Ano âncora do dado exibido (última cotação real). */
  ano_referencia?: number | null
  /** REAL_ATUAL | HISTORICO_BASE | FALLBACK_DIMENSAO */
  tipo_dado?: string | null
  /** Texto de proveniência da API (sem R$). */
  mensagem_transparencia?: string | null
  /** True quando ano_referencia < ano corrente. */
  is_dado_legado?: boolean
  /** Tamanho do ícone em px (default 14). */
  size?: number
  className?: string
}

function anoAtual(): number {
  return new Date().getFullYear()
}

function titulo(tipo: string | null | undefined, ano: number | null | undefined): string {
  if (!tipo) return 'Dado de Referência'
  if (tipo === 'REAL_ATUAL') return 'Dado Atual'
  if (tipo === 'HISTORICO_BASE') return `Ano de Origem: ${ano ?? '—'}`
  return 'Dado de Referência'
}

function badgeLabel(tipo: string | null | undefined): string {
  if (tipo === 'REAL_ATUAL') return 'Coleta Efetiva'
  if (tipo === 'HISTORICO_BASE') return 'Histórico Real CONAB'
  return 'Referência'
}

function defasagemLabel(ano: number | null | undefined, isLegado?: boolean): string | null {
  if (!isLegado || ano == null) return null
  const diff = anoAtual() - ano
  if (diff <= 0) return null
  return diff === 1 ? 'Histórico de 1 ano atrás' : `Histórico de ${diff} anos atrás`
}

/**
 * Ícone (i) circulado com tooltip/popover explicativo de transparência temporal.
 *
 * - Renderiza `null` quando `!tipo_dado` (contrato aditivo — consumidores antigos
 *   sem os novos campos continuam funcionando).
 * - NUNCA renderiza R$ (R-ADD-03/S3) — apenas ano, tipo, defasagem e proveniência.
 */
export function DataTransparencyInfo({
  ano_referencia,
  tipo_dado,
  mensagem_transparencia,
  is_dado_legado,
  size = 14,
  className,
}: DataTransparencyInfoProps) {
  if (!tipo_dado) return null

  const dif = defasagemLabel(ano_referencia, is_dado_legado)

  return (
    <span className={cn('group relative inline-flex items-center', className)}>
      <span
        role="button"
        tabIndex={0}
        aria-label={`Informação de transparência — ${badgeLabel(tipo_dado)}`}
        className="border-current/40 hover:bg-current/10 inline-flex h-[18px] w-[18px] cursor-help items-center justify-center rounded-full border bg-transparent text-current transition-colors"
      >
        <Info size={size} strokeWidth={1.5} aria-hidden="true" />
      </span>
      <span
        role="tooltip"
        className="pointer-events-none absolute bottom-full left-1/2 z-50 mb-1.5 hidden w-56 -translate-x-1/2 group-focus-within:block group-hover:block"
      >
        <span className="block rounded-clay-sm border border-gray-200 bg-white px-3 py-2 text-left shadow-clay-card dark:border-gray-700 dark:bg-gray-900 dark:shadow-clay-dark">
          <span className="flex items-center justify-between gap-2">
            <span className="text-xs font-semibold text-gray-900 dark:text-gray-100">
              {titulo(tipo_dado, ano_referencia)}
            </span>
            <Badge variant="outline" className="shrink-0 text-[9px] font-medium">
              {badgeLabel(tipo_dado)}
            </Badge>
          </span>
          <span className="mt-1 block text-[11px] leading-snug text-gray-600 dark:text-gray-300">
            Este valor reflete a última cotação real registrada para este produto no mês
            correspondente. Não é uma estimativa sintética.
          </span>
          {dif && (
            <span className="mt-1 block text-[10px] font-medium text-amber-600 dark:text-amber-400">
              {dif}
            </span>
          )}
          {mensagem_transparencia && (
            <span className="mt-1 block text-[10px] leading-snug text-gray-400 dark:text-gray-500">
              {mensagem_transparencia}
            </span>
          )}
        </span>
      </span>
    </span>
  )
}
