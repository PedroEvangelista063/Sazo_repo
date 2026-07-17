import { motion, AnimatePresence } from 'framer-motion'
import { Badge } from '@/components/ui/badge'
import { X, MapPin, ShoppingBasket, Package, Truck } from 'lucide-react'
import { cn } from '@/lib/utils'
import SpotlightCard from '@/components/SpotlightCard'
import type { RegiaoInfo, ProdutoVarejo, FlowItem } from '@/types/domain'

function groupBy<T>(arr: T[], keyFn: (item: T) => string): Record<string, T[]> {
  return arr.reduce(
    (acc, item) => {
      const k = keyFn(item)
      if (!acc[k]) acc[k] = []
      acc[k].push(item)
      return acc
    },
    {} as Record<string, T[]>,
  )
}

interface RegiaoPanelProps {
  regiao: RegiaoInfo | null
  selectedUF?: string | null
  produtos: ProdutoVarejo[]
  fluxos?: FlowItem[]
  isLoading: boolean
  isError: boolean
  onClose: () => void
  onPoloClick: (uf: string) => void
  className?: string
}

const STATUS_CONFIG = {
  VERDE: { label: 'Melhor época', class: 'text-sazonal-verde-600 dark:text-sazonal-verde-400' },
  AMARELO: { label: 'Preço normal', class: 'text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400' },
  VERMELHO: { label: 'Péssima época', class: 'text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400' },
}

export function RegiaoPanel({
  regiao,
  selectedUF,
  produtos,
  fluxos,
  isLoading,
  isError,
  onClose,
  onPoloClick,
  className,
}: RegiaoPanelProps) {
  const totalUfsComDado = new Set(produtos.map((p) => p.uf)).size

  return (
    <AnimatePresence mode="wait">
      {regiao ? (
        <SpotlightCard
          spotlightColor="rgba(22, 163, 74, 0.08)"
          className={cn(
            'border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800',
            'rounded-xl shadow-sm',
            className,
          )}
        >
          <motion.div
            key={regiao.id}
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            transition={{ duration: 0.2 }}
          >
            <div className="flex items-center justify-between mb-3">
              <div>
                <h3 className="text-lg font-bold text-gray-900 dark:text-gray-100">
                  {regiao.nome}
                </h3>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  {regiao.ufs.join(', ')}
                </p>
              </div>
              <button
                onClick={onClose}
                className="p-1 rounded-md hover:bg-gray-100 dark:hover:bg-gray-700 text-gray-400 transition-colors"
                aria-label="Fechar painel"
              >
                <X size={18} />
              </button>
            </div>

            {!isLoading && !isError && produtos.length > 0 && (
              <div className="flex items-center gap-2 mb-3">
                <Badge variant="secondary" className="text-xs shadow-sm">
                  {produtos.length} produtos
                </Badge>
                <span className="text-xs text-gray-400">
                  {totalUfsComDado}/{regiao.total_ufs} UFs com dados
                </span>
              </div>
            )}

            {!isLoading && !isError && produtos.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mb-4">
                {(Object.entries(STATUS_CONFIG) as [string, typeof STATUS_CONFIG['VERDE']][]).map(
                  ([status, info]) => {
                    const count = produtos.filter((p) => p.status_cor === status).length
                    if (count === 0) return null
                    return (
                      <Badge
                        key={status}
                        variant="outline"
                        className={cn('text-[10px] shadow-sm', info.class)}
                      >
                        {count} {info.label}
                      </Badge>
                    )
                  },
                )}
              </div>
            )}

            {isLoading && (
              <div className="flex items-center justify-center py-6">
                <div className="animate-spin h-5 w-5 border-2 border-gray-300 border-t-sazonal-verde-600 rounded-full" />
              </div>
            )}

            {isError && (
              <p className="text-xs text-red-500 py-2">
                Erro ao carregar dados regionais.
              </p>
            )}

            <div className="space-y-1">
              <p className="text-[11px] font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-1.5">
                Polos CEASA
              </p>
              {regiao.polos.map((polo) => (
                <motion.button
                  key={polo.nome}
                  onClick={() => onPoloClick(polo.uf)}
                  whileHover={{ x: 3 }}
                  className={cn(
                    'flex items-center gap-2 w-full text-left px-2.5 py-1.5 rounded-lg',
                    'hover:bg-gray-100 dark:hover:bg-gray-700/50',
                    'text-sm text-gray-700 dark:text-gray-300',
                    'transition-all duration-150',
                  )}
                >
                  <MapPin size={14} className="shrink-0 text-gray-400" />
                  <span className="flex-1 truncate">{polo.nome}</span>
                  <span className="text-[10px] text-gray-400">{polo.uf}</span>
                  {polo.fonte_id ? (
                    <ShoppingBasket size={12} className="text-sazonal-verde-500 shrink-0" />
                  ) : (
                    <span className="text-[9px] text-gray-400 shrink-0">sem dados</span>
                  )}
                </motion.button>
              ))}
            </div>

            {/* Fluxos de Abastecimento */}
            {fluxos && fluxos.length > 0 && (
              <div className="mt-4 space-y-1.5">
                <p className="text-[11px] font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-1.5 flex items-center gap-1.5">
                  <Truck size={12} />
                  Fluxos de Abastecimento
                </p>
                {fluxos.map((flow) => (
                  <div
                    key={flow.id}
                    className="flex items-center gap-2 px-2.5 py-1.5 rounded-lg bg-gray-50 dark:bg-gray-700/30"
                  >
                    <div
                      className="w-2 h-2 rounded-full shrink-0"
                      style={{ backgroundColor: flow.cor_indicadora }}
                    />
                    <Package size={12} className="shrink-0 text-gray-400" />
                    <span className="text-xs text-gray-700 dark:text-gray-300 flex-1 truncate">
                      {flow.item}
                    </span>
                    <span className="text-[10px] text-gray-400 shrink-0">
                      {flow.origem_uf} → {flow.destino_uf}
                    </span>
                    <span
                      className={cn(
                        'text-[9px] px-1.5 py-0.5 rounded-full shrink-0 font-medium',
                        flow.tipo === 'autossuficiente'
                          ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
                          : flow.tipo === 'exportado'
                            ? 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400'
                            : 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
                      )}
                    >
                      {flow.tipo === 'autossuficiente'
                        ? 'local'
                        : flow.tipo === 'exportado'
                          ? 'exporta'
                          : 'importa'}
                    </span>
                  </div>
                ))}
              </div>
            )}

            {regiao.id === 'sudeste' && totalUfsComDado < 4 && (
              <p className="mt-3 text-[10px] text-amber-600 dark:text-amber-400 bg-amber-50 dark:bg-amber-900/20 rounded-md px-2 py-1">
                SP com dados parciais — resultados podem subestimar a cobertura
              </p>
            )}
          </motion.div>
        </SpotlightCard>
      ) : selectedUF ? (
        <SpotlightCard
          spotlightColor="rgba(22, 163, 74, 0.08)"
          className={cn(
            'border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800',
            'rounded-xl shadow-sm',
            className,
          )}
        >
          <motion.div
            key={`uf-${selectedUF}`}
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.2 }}
          >
            <div className="flex items-center justify-between mb-3">
              <div>
                <h3 className="text-lg font-bold text-gray-900 dark:text-gray-100">
                  {selectedUF}
                </h3>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Fluxos de abastecimento
                </p>
              </div>
              <button
                onClick={onClose}
                className="p-1 rounded-md hover:bg-gray-100 dark:hover:bg-gray-700 text-gray-400 transition-colors"
                aria-label="Fechar painel"
              >
                <X size={18} />
              </button>
            </div>

            {fluxos && fluxos.length > 0 ? (
              <div className="space-y-4">
                {/* Recebe de */}
                {(() => {
                  const incoming = fluxos.filter((f) => f.destino_uf === selectedUF && f.origem_uf !== selectedUF)
                  if (incoming.length === 0) return null
                  const porOrigem = groupBy(incoming, (f) => f.origem_uf)
                  return (
                    <div>
                      <p className="text-[11px] font-medium text-blue-600 dark:text-blue-400 uppercase tracking-wide mb-1.5 flex items-center gap-1">
                        <Truck size={12} />
                        Recebe de
                      </p>
                      <div className="space-y-1">
                        {Object.entries(porOrigem).map(([origemUf, flows]) => (
                          <div key={origemUf} className="flex items-start gap-2 px-2.5 py-1.5 rounded-lg bg-blue-50 dark:bg-blue-900/20">
                            <span className="text-xs font-bold text-blue-700 dark:text-blue-300 mt-0.5 shrink-0 w-6">{origemUf}</span>
                            <div className="flex flex-wrap gap-1">
                              {flows.map((f) => (
                                <span key={f.id} className="text-[10px] bg-white dark:bg-gray-700 rounded px-1.5 py-0.5 text-gray-700 dark:text-gray-300 shadow-sm">
                                  {f.item}
                                </span>
                              ))}
                            </div>
                          </div>
                        ))}
                      </div>
                    </div>
                  )
                })()}

                {/* Envia para */}
                {(() => {
                  const outgoing = fluxos.filter((f) => f.origem_uf === selectedUF && f.destino_uf !== selectedUF)
                  if (outgoing.length === 0) return null
                  const porDestino = groupBy(outgoing, (f) => f.destino_uf)
                  return (
                    <div>
                      <p className="text-[11px] font-medium text-green-600 dark:text-green-400 uppercase tracking-wide mb-1.5 flex items-center gap-1">
                        <Truck size={12} />
                        Envia para
                      </p>
                      <div className="space-y-1">
                        {Object.entries(porDestino).map(([destinoUf, flows]) => (
                          <div key={destinoUf} className="flex items-start gap-2 px-2.5 py-1.5 rounded-lg bg-green-50 dark:bg-green-900/20">
                            <span className="text-xs font-bold text-green-700 dark:text-green-300 mt-0.5 shrink-0 w-6">{destinoUf}</span>
                            <div className="flex flex-wrap gap-1">
                              {flows.map((f) => (
                                <span key={f.id} className="text-[10px] bg-white dark:bg-gray-700 rounded px-1.5 py-0.5 text-gray-700 dark:text-gray-300 shadow-sm">
                                  {f.item}
                                </span>
                              ))}
                            </div>
                          </div>
                        ))}
                      </div>
                    </div>
                  )
                })()}

                {/* Produção local */}
                {(() => {
                  const local = fluxos.filter((f) => f.origem_uf === selectedUF && f.destino_uf === selectedUF)
                  if (local.length === 0) return null
                  return (
                    <div>
                      <p className="text-[11px] font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-1.5 flex items-center gap-1">
                        <Package size={12} />
                        Produção local
                      </p>
                      <div className="flex flex-wrap gap-1">
                        {local.map((f) => (
                          <span key={f.id} className="text-[10px] bg-gray-100 dark:bg-gray-700 rounded px-1.5 py-0.5 text-gray-600 dark:text-gray-300 shadow-sm">
                            {f.item}
                          </span>
                        ))}
                      </div>
                    </div>
                  )
                })()}
              </div>
            ) : (
              <div className="flex items-center justify-center py-6">
                <p className="text-xs text-gray-400">
                  Nenhum fluxo registrado para {selectedUF}.
                </p>
              </div>
            )}
          </motion.div>
        </SpotlightCard>
      ) : (
        <motion.div
          key="empty"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className={cn(
            'rounded-xl border border-dashed border-gray-300 dark:border-gray-600',
            'bg-gray-50 dark:bg-gray-800/50 p-6 text-center',
            'shadow-inner',
            className,
          )}
        >
          <MapPin size={32} className="mx-auto mb-2 text-gray-300 dark:text-gray-600" />
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Clique em uma região ou estado no mapa
          </p>
        </motion.div>
      )}
    </AnimatePresence>
  )
}
