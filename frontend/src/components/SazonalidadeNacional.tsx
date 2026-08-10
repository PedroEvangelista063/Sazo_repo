import { useMemo } from 'react'
import { motion } from 'framer-motion'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { DataTransparencyInfo } from '@/components/DataTransparencyInfo'
import type { SazonalidadeNacionalItem, StatusCor } from '@/types/domain'

const MONTHS_SHORT = [
  'Jan',
  'Fev',
  'Mar',
  'Abr',
  'Mai',
  'Jun',
  'Jul',
  'Ago',
  'Set',
  'Out',
  'Nov',
  'Dez',
]

const STATUS_STYLES: Record<
  StatusCor,
  { bg: string; text: string; border: string; label: string }
> = {
  VERDE: {
    bg: 'bg-sazonal-verde-600/20 dark:bg-sazonal-verde-700/45',
    text: 'text-sazonal-verde-700 dark:text-sazonal-verde-400',
    border: 'border-sazonal-verde-600/45 dark:border-sazonal-verde-400/45',
    label: 'Melhor Época',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-600/20 dark:bg-sazonal-amarelo-dark/45',
    text: 'text-sazonal-amarelo-dark dark:text-sazonal-amarelo-400',
    border: 'border-sazonal-amarelo-600/45 dark:border-sazonal-amarelo-400/45',
    label: 'Preço Normal',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-600/20 dark:bg-sazonal-vermelho-dark/45',
    text: 'text-sazonal-vermelho-dark dark:text-sazonal-vermelho-400',
    border: 'border-sazonal-vermelho-600/45 dark:border-sazonal-vermelho-400/45',
    label: 'Péssima Época',
  },
}

interface SazonalidadeNacionalProps {
  data: SazonalidadeNacionalItem[]
  className?: string
}

function anoAtual(): number {
  return new Date().getFullYear()
}

/** Badge de ano âncora: '26 (atual) / '25 / '24 — sem texto sintético. */
function yearBadge(ano: number | null | undefined): string | null {
  if (ano == null) return null
  return `'${String(ano).slice(2)}`
}

export function SazonalidadeNacional({ data, className }: SazonalidadeNacionalProps) {
  const sorted = useMemo(() => [...data].sort((a, b) => a.produto.localeCompare(b.produto)), [data])

  return (
    <div className={cn('overflow-x-auto', className)}>
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr>
            <th className="sticky left-0 z-10 min-w-[180px] bg-[var(--bg-header)] px-3 py-2 text-left font-semibold text-gray-700 dark:bg-gray-800 dark:text-gray-300">
              Produto
            </th>
            {MONTHS_SHORT.map((name, idx) => (
              <th
                key={idx}
                className="min-w-[52px] px-1 py-2 text-center text-xs font-medium text-gray-500 dark:text-gray-400"
              >
                {name}
              </th>
            ))}
            <th className="px-2 py-2 text-center text-xs text-gray-400">UFs</th>
          </tr>
        </thead>
        <tbody>
          {sorted.map((item, rowIdx) => (
            <motion.tr
              key={item.produto}
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.2, delay: Math.min(rowIdx * 0.02, 0.5) }}
              className="border-t border-gray-100 hover:bg-gray-50 dark:border-gray-800 dark:hover:bg-gray-800/50"
            >
              <td className="sticky left-0 z-10 bg-white px-3 py-2 text-sm font-medium text-gray-900 dark:bg-gray-900 dark:text-gray-100">
                {item.produto}
                {item.categoria && (
                  <span className="ml-1 text-[10px] text-gray-400 dark:text-gray-500">
                    {item.categoria}
                  </span>
                )}
              </td>
              {Array.from({ length: 12 }, (_, i) => i + 1).map((mesNum) => {
                const mesData = item.meses.find((m) => m.mes === mesNum)
                const isLegado =
                  Boolean(mesData?.is_dado_legado) ||
                  (mesData?.ano_referencia != null && mesData.ano_referencia < anoAtual())
                const badge = yearBadge(mesData?.ano_referencia)

                if (!mesData) {
                  // Defensivo: sem linha no mês → célula vazia muted (novo modelo
                  // preenche todos os meses do ano corrente com dado real/âncora).
                  return (
                    <td key={mesNum} className="px-1 py-1.5 text-center">
                      <div className="h-8 w-full rounded border border-transparent bg-gray-50 dark:bg-gray-800/60" />
                    </td>
                  )
                }

                const style = STATUS_STYLES[mesData.status_cor] ?? {
                  bg: 'bg-gray-100 dark:bg-gray-800/40',
                  text: 'text-gray-400 dark:text-gray-500',
                  border: 'border-gray-200/70 dark:border-gray-700/60',
                  label: 'Sem Cotação',
                }
                return (
                  <td key={mesNum} className="px-1 py-1.5 text-center">
                    <div className="group relative flex h-8 w-full items-center justify-center gap-1 rounded-md border">
                      <div
                        className={cn(
                          'shadow-clay-press flex h-full w-full cursor-default items-center justify-center rounded-md border dark:shadow-clay-dark',
                          style.bg,
                          style.text,
                          style.border,
                        )}
                        aria-label={`${item.produto} — ${MONTHS_SHORT[mesNum - 1]}: ${style.label}`}
                      >
                        {badge && (
                          <span className="text-[9px] font-semibold opacity-80">{badge}</span>
                        )}
                      </div>
                      {(isLegado || mesData.tipo_dado) && (
                        <DataTransparencyInfo
                          status_cor={mesData.status_cor}
                          tipo_dado={mesData.tipo_dado}
                          ano_referencia={mesData.ano_referencia}
                          mensagem_transparencia={mesData.mensagem_transparencia}
                          is_dado_legado={isLegado}
                          size={11}
                          className="absolute right-0.5 top-0.5"
                        />
                      )}
                    </div>
                  </td>
                )
              })}
              <td className="px-2 py-1.5 text-center">
                <Badge variant="outline" className="text-[10px] font-normal text-gray-500">
                  {item.total_ufs}
                </Badge>
              </td>
            </motion.tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
