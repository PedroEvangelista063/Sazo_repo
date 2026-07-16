import { useMemo } from 'react'
import { motion } from 'framer-motion'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import type { SazonalidadeNacionalItem, StatusCor } from '@/types/domain'

const MONTHS_SHORT = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']

const STATUS_STYLES: Record<StatusCor, { bg: string; text: string; border: string; label: string }> = {
  VERDE: {
    bg: 'bg-sazonal-verde-100 dark:bg-sazonal-verde-900/30',
    text: 'text-sazonal-verde-700 dark:text-sazonal-verde-300',
    border: 'border-sazonal-verde-300 dark:border-sazonal-verde-700',
    label: 'Melhor Época',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-100 dark:bg-sazonal-amarelo-900/30',
    text: 'text-sazonal-amarelo-700 dark:text-sazonal-amarelo-300',
    border: 'border-sazonal-amarelo-300 dark:border-sazonal-amarelo-700',
    label: 'Preço Normal',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-100 dark:bg-sazonal-vermelho-900/30',
    text: 'text-sazonal-vermelho-700 dark:text-sazonal-vermelho-300',
    border: 'border-sazonal-vermelho-300 dark:border-sazonal-vermelho-700',
    label: 'Péssima Época',
  },
}

interface SazonalidadeNacionalProps {
  data: SazonalidadeNacionalItem[]
  className?: string
}

export function SazonalidadeNacional({ data, className }: SazonalidadeNacionalProps) {
  const sorted = useMemo(
    () => [...data].sort((a, b) => a.produto.localeCompare(b.produto)),
    [data],
  )

  return (
    <div className={cn('overflow-x-auto', className)}>
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr>
            <th className="sticky left-0 z-10 bg-[var(--bg-header)] dark:bg-gray-800 text-left px-3 py-2 font-semibold text-gray-700 dark:text-gray-300 min-w-[180px]">
              Produto
            </th>
            {MONTHS_SHORT.map((name, idx) => (
              <th
                key={idx}
                className="px-1 py-2 text-center font-medium text-gray-500 dark:text-gray-400 text-xs min-w-[52px]"
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
              className="border-t border-gray-100 dark:border-gray-800 hover:bg-gray-50 dark:hover:bg-gray-800/50"
            >
              <td className="sticky left-0 z-10 bg-white dark:bg-gray-900 px-3 py-2 font-medium text-gray-900 dark:text-gray-100 text-sm">
                {item.produto}
                {item.categoria && (
                  <span className="ml-1 text-[10px] text-gray-400 dark:text-gray-500">
                    {item.categoria}
                  </span>
                )}
              </td>
              {Array.from({ length: 12 }, (_, i) => i + 1).map((mesNum) => {
                const mesData = item.meses.find((m) => m.mes === mesNum)
                if (!mesData) {
                  return (
                    <td key={mesNum} className="px-1 py-1.5 text-center">
                      <div className="w-full h-8 rounded bg-gray-100 dark:bg-gray-800" />
                    </td>
                  )
                }
                const style = STATUS_STYLES[mesData.status_cor]
                return (
                  <td key={mesNum} className="px-1 py-1.5 text-center">
                    <div className="relative group">
                      <motion.div
                        whileHover={{ scale: 1.15 }}
                        className={cn(
                          'w-full h-8 rounded-md border flex items-center justify-center cursor-default',
                          style.bg,
                          style.text,
                          style.border,
                        )}
                      >
                        {mesData.is_forecast && (
                          <span className="text-[8px] absolute top-0 right-0.5 opacity-60">📈</span>
                        )}
                      </motion.div>
                      <div className="absolute bottom-full mb-1 left-1/2 -translate-x-1/2 hidden group-hover:block z-50 pointer-events-none">
                        <div className="bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-[10px] rounded px-2 py-1 whitespace-nowrap shadow-lg">
                          {item.produto} — {MONTHS_SHORT[mesNum - 1]}: {style.label}
                          {mesData.is_forecast && (
                            <span className="block text-gray-300 dark:text-gray-600">
                              📈 Estimativa
                              {mesData.baseline_confianca != null && (
                                <> — {mesData.baseline_confianca}%</>
                              )}
                            </span>
                          )}
                        </div>
                      </div>
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
