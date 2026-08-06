import { useMemo, useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { ChevronDown } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { SazonalidadeNacional } from '@/components/SazonalidadeNacional'
import { agruparPorMacrocategoria, type MacrocategoriaId } from '@/utils/categorizacaoProdutos'
import { cn } from '@/lib/utils'
import type { SazonalidadeNacionalItem } from '@/types/domain'

interface GradeSazonalAcordeaoProps {
  /** Itens da grade sazonal nacional (BR) — agrupados por macrocategoria. */
  data: SazonalidadeNacionalItem[]
  /** IDs abertos por padrão (além da categoria destaque). */
  defaultOpenIds?: MacrocategoriaId[]
  /** Abre a categoria com mais itens por padrão (destaque). Default: true. */
  abrirDestaque?: boolean
  className?: string
}

/**
 * Grade Sazonal agrupada em macrocategorias (accordion/tree view).
 *
 * - **UX:** múltiplos grupos podem ficar abertos; vêm fechados por padrão,
 *   com exceção da categoria destaque (a maior, se `abrirDestaque`).
 * - **Performance:** o conteúdo só é montado no DOM quando o grupo é aberto
 *   (lazy mount) — evita o custo de 200+ linhas simultâneas no scroll.
 * - **Sticky:** o header da categoria gruda logo abaixo do header do app
 *   (`sticky top-14`) enquanto o usuário rola pela lista do grupo.
 */
export function GradeSazonalAcordeao({
  data,
  defaultOpenIds = [],
  abrirDestaque = true,
  className,
}: GradeSazonalAcordeaoProps) {
  const grupos = useMemo(() => agruparPorMacrocategoria(data), [data])

  const destaqueId = useMemo(() => {
    if (grupos.length === 0) return undefined
    return grupos.reduce((maior, g) => (g.itens.length > maior.itens.length ? g : maior)).id
  }, [grupos])

  const [abertos, setAbertos] = useState<Set<MacrocategoriaId>>(() => {
    const inicial = new Set<MacrocategoriaId>(defaultOpenIds)
    if (abrirDestaque && destaqueId && inicial.size === 0) inicial.add(destaqueId)
    return inicial
  })

  const alternar = (id: MacrocategoriaId) => {
    setAbertos((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  if (grupos.length === 0) {
    return <p className="py-4 text-center text-sm text-gray-400">Sem dados para exibir.</p>
  }

  return (
    <div className={cn('flex flex-col gap-3', className)}>
      {grupos.map((grupo) => {
        const aberto = abertos.has(grupo.id)
        return (
          <section
            key={grupo.id}
            className="rounded-clay border border-gray-200 bg-white/80 shadow-clay-card backdrop-blur-sm dark:border-gray-700 dark:bg-gray-800/80 dark:shadow-clay-dark"
          >
            {/* Header sticky — gruda abaixo do header do app enquanto rola */}
            <button
              type="button"
              id={`acordeao-btn-${grupo.id}`}
              onClick={() => alternar(grupo.id)}
              aria-expanded={aberto}
              aria-controls={`acordeao-${grupo.id}`}
              className={cn(
                'sticky top-14 z-20 flex w-full items-center gap-3 rounded-clay border border-transparent px-4 py-3 text-left',
                'bg-white/95 shadow-clay-btn backdrop-blur-sm transition-all duration-150',
                'hover:shadow-clay-btn-hover active:translate-y-[1px] active:shadow-clay-press',
                'dark:bg-gray-800/95 dark:shadow-clay-dark dark:hover:shadow-clay-dark-hover',
              )}
            >
              <span className="text-xl leading-none" aria-hidden="true">
                {grupo.emoji}
              </span>
              <span className="min-w-0 flex-1">
                <span className="block truncate font-display text-sm font-bold text-gray-900 dark:text-gray-100">
                  {grupo.nome}
                </span>
                <span className="block truncate text-[10px] text-gray-400 dark:text-gray-500">
                  {grupo.descricao}
                </span>
              </span>
              <Badge variant="secondary" className="shrink-0 text-xs shadow-sm">
                {grupo.itens.length}
              </Badge>
              <ChevronDown
                size={16}
                className={cn(
                  'shrink-0 text-gray-400 transition-transform duration-300',
                  aberto && 'rotate-180',
                )}
              />
            </button>

            {/* Conteúdo lazy: montado apenas quando o grupo está aberto.
                overflow-clip (não overflow-hidden) para NÃO criar scroll container:
                preserve o sticky horizontal da coluna Produto da tabela interna. */}
            <AnimatePresence initial={false}>
              {aberto && (
                <motion.div
                  key="conteudo"
                  id={`acordeao-${grupo.id}`}
                  role="region"
                  aria-labelledby={`acordeao-btn-${grupo.id}`}
                  initial={{ height: 0, opacity: 0 }}
                  animate={{ height: 'auto', opacity: 1 }}
                  exit={{ height: 0, opacity: 0 }}
                  transition={{ duration: 0.25, ease: 'easeInOut' }}
                  className="overflow-clip"
                >
                  <div className="px-2 pb-3 pt-1">
                    <SazonalidadeNacional data={grupo.itens} />
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
          </section>
        )
      })}
    </div>
  )
}
