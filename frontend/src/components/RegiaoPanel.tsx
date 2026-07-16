import { motion, AnimatePresence } from 'framer-motion'
import { Badge } from '@/components/ui/badge'
import { X, MapPin, ShoppingBasket } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { RegiaoInfo, ProdutoVarejo } from '@/types/domain'

interface RegiaoPanelProps {
  regiao: RegiaoInfo | null
  produtos: ProdutoVarejo[]
  isLoading: boolean
  isError: boolean
  onClose: () => void
  onPoloClick: (uf: string) => void
  className?: string
}

const STATUS_COUNTS = {
  VERDE: { label: 'Melhor época', class: 'text-sazonal-verde-600 dark:text-sazonal-verde-400' },
  AMARELO: { label: 'Preço normal', class: 'text-sazonal-amarelo-600 dark:text-sazonal-amarelo-400' },
  VERMELHO: { label: 'Péssima época', class: 'text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400' },
}

export function RegiaoPanel({
  regiao,
  produtos,
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
        <motion.div
          key={regiao.id}
          initial={{ opacity: 0, x: 20 }}
          animate={{ opacity: 1, x: 0 }}
          exit={{ opacity: 0, x: -20 }}
          transition={{ duration: 0.2 }}
          className={cn(
            'rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4 shadow-sm',
            className,
          )}
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
              className="p-1 rounded-md hover:bg-gray-100 dark:hover:bg-gray-700 text-gray-400"
              aria-label="Fechar painel"
            >
              <X size={18} />
            </button>
          </div>

          {!isLoading && !isError && produtos.length > 0 && (
            <div className="flex items-center gap-2 mb-3">
              <Badge variant="secondary" className="text-xs">
                {produtos.length} produtos
              </Badge>
              <span className="text-xs text-gray-400">
                {totalUfsComDado}/{regiao.total_ufs} UFs com dados
              </span>
            </div>
          )}

          {!isLoading && !isError && produtos.length > 0 && (
            <div className="flex gap-2 mb-4">
              {(Object.entries(STATUS_COUNTS) as [string, typeof STATUS_COUNTS['VERDE']][]).map(
                ([status, info]) => {
                  const count = produtos.filter((p) => p.status_cor === status).length
                  if (count === 0) return null
                  return (
                    <Badge
                      key={status}
                      variant="outline"
                      className={cn('text-[10px]', info.class)}
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

          <div className="space-y-1.5">
            <p className="text-[11px] font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">
              Polos CEASA
            </p>
            {regiao.polos.map((polo) => (
              <motion.button
                key={polo.nome}
                onClick={() => onPoloClick(polo.uf)}
                whileHover={{ x: 3 }}
                className={cn(
                  'flex items-center gap-2 w-full text-left px-2.5 py-1.5 rounded-md',
                  'hover:bg-gray-100 dark:hover:bg-gray-700/50',
                  'text-sm text-gray-700 dark:text-gray-300',
                )}
              >
                <MapPin size={14} className="shrink-0 text-gray-400" />
                <span className="flex-1">{polo.nome}</span>
                <span className="text-[10px] text-gray-400">{polo.uf}</span>
                {polo.fonte_id ? (
                  <ShoppingBasket size={12} className="text-sazonal-verde-500" />
                ) : (
                  <span className="text-[9px] text-gray-400">sem dados</span>
                )}
              </motion.button>
            ))}
          </div>

          {regiao.id === 'sudeste' && totalUfsComDado < 4 && (
            <p className="mt-3 text-[10px] text-amber-600 dark:text-amber-400 bg-amber-50 dark:bg-amber-900/20 rounded-md px-2 py-1">
              SP com dados parciais — resultados podem subestimar a cobertura
            </p>
          )}
        </motion.div>
      ) : (
        <motion.div
          key="empty"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className={cn(
            'rounded-xl border border-dashed border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-800/50 p-6 text-center',
            className,
          )}
        >
          <MapPin size={32} className="mx-auto mb-2 text-gray-300 dark:text-gray-600" />
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Clique em uma região no mapa
          </p>
        </motion.div>
      )}
    </AnimatePresence>
  )
}
