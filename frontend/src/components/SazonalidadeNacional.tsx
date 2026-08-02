import { useMemo } from 'react'
import { motion } from 'framer-motion'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
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

function formatDataPtBr(iso: string | null | undefined): string | null {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  const day = String(d.getDate()).padStart(2, '0')
  const month = String(d.getMonth() + 1).padStart(2, '0')
  return `Coletado em ${day}/${month}/${d.getFullYear()}`
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
                if (!mesData) {
                  return (
                    <td key={mesNum} className="px-1 py-1.5 text-center">
                      <div className="group relative">
                        <div className="h-8 w-full rounded border border-dashed border-gray-200 bg-gray-100 dark:border-gray-700/50 dark:bg-gray-800" />
                        <div className="pointer-events-none absolute bottom-full left-1/2 z-50 mb-1 hidden -translate-x-1/2 group-hover:block">
                          <div className="whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-[10px] text-white shadow-lg dark:bg-gray-100 dark:text-gray-900">
                            {item.produto} — {MONTHS_SHORT[mesNum - 1]}: Sem cotações coletadas
                          </div>
                        </div>
                      </div>
                    </td>
                  )
                }
                const style = STATUS_STYLES[mesData.status_cor]
                const isLowCoverage = item.total_ufs < 3
                const method = mesData.forecast_method
                const isRealData = !mesData.is_forecast || !method
                const calculadoEm = formatDataPtBr(mesData.calculado_em)
                return (
                  <td key={mesNum} className="px-1 py-1.5 text-center">
                    <div className="group relative">
                      <motion.div
                        whileHover={{ scale: 1.15 }}
                        className={cn(
                          'flex h-8 w-full cursor-default items-center justify-center rounded-md border',
                          style.bg,
                          style.text,
                          style.border,
                        )}
                      >
                        {mesData.is_forecast && (
                          <span className="absolute right-0.5 top-0 text-[8px] opacity-60">📈</span>
                        )}
                      </motion.div>
                      <div className="pointer-events-none absolute bottom-full left-1/2 z-50 mb-1 hidden -translate-x-1/2 group-hover:block">
                        <div className="whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-[10px] text-white shadow-lg dark:bg-gray-100 dark:text-gray-900">
                          {item.produto} — {MONTHS_SHORT[mesNum - 1]}: {style.label}
                          {isLowCoverage && (
                            <span className="block font-medium text-amber-300 dark:text-amber-600">
                              ⚠️ Cobertura em {item.total_ufs} UF{item.total_ufs > 1 ? 's' : ''}
                            </span>
                          )}
                          {isRealData ? (
                            <>
                              <span className="block text-gray-300 dark:text-gray-600">
                                ✅ Dado real coletado via CEASA/CONAB
                              </span>
                              {calculadoEm && (
                                <span className="block text-gray-300 dark:text-gray-600">
                                  {calculadoEm}
                                </span>
                              )}
                            </>
                          ) : method === 'ANCHOR_2024_MARGIN_2025' ? (
                            <>
                              <span className="block text-gray-300 dark:text-gray-600">
                                📈 Previsão baseada no histórico 2024 com ajuste de tendência 2025
                              </span>
                              <span className="block text-gray-300 dark:text-gray-600">
                                📈 Estimativa
                                {mesData.baseline_confianca != null && (
                                  <> — {mesData.baseline_confianca}%</>
                                )}
                              </span>
                            </>
                          ) : method === 'PROXY_CATEGORIA_UF' ? (
                            <span className="block text-gray-300 dark:text-gray-600">
                              📈 Sem histórico — média da categoria (confiança baixa)
                              {mesData.baseline_confianca != null && (
                                <> — {mesData.baseline_confianca}%</>
                              )}
                            </span>
                          ) : method === 'LOCF_MES_ANTERIOR' ? (
                            <span className="block text-gray-300 dark:text-gray-600">
                              📈 Sem histórico — último status real conhecido do produto
                              {mesData.baseline_confianca != null && (
                                <> — {mesData.baseline_confianca}%</>
                              )}
                            </span>
                          ) : (
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
