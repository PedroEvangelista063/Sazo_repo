'use client'

import { motion, AnimatePresence } from 'framer-motion'
import { useMemo, useEffect } from 'react'
import type { ProdutoVarejo } from '@/types/domain'
import { useHortifruti } from '@/hooks/useHortifruti'
import { Skeleton } from '@/components/ui/skeleton'

const UF_EMOJI: Record<string, string> = {
  AC: '🌿',
  AL: '🌊',
  AP: '🌴',
  AM: '🌿',
  BA: '☀️',
  CE: '🌵',
  DF: '🏛️',
  ES: '🌊',
  GO: '🌾',
  MA: '🌴',
  MT: '🌄',
  MS: '🌿',
  MG: '⛰️',
  PA: '🌳',
  PB: '🌵',
  PR: '🌲',
  PE: '🌊',
  PI: '🌾',
  RJ: '🏖️',
  RN: '🌵',
  RS: '🌾',
  RO: '🌿',
  RR: '🌴',
  SC: '🏔️',
  SP: '🏙️',
  SE: '🌊',
  TO: '🌾',
  BR: '🇧🇷',
}

const MESES_ABREV = [
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

interface SearchResult {
  produto: ProdutoVarejo
  score: number
}

interface SearchResultsModalProps {
  query: string
  produtos: ProdutoVarejo[]
  onSelectResult: (uf: string, nomeProduto: string) => void
  onClose: () => void
  visible: boolean
}

function norm(s: string): string {
  return s
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
}

function getBigrams(s: string): Set<string> {
  const bg = new Set<string>()
  for (let i = 0; i < s.length - 1; i++) bg.add(s.slice(i, i + 2))
  return bg
}

function bigramSimilarity(a: string, b: string): number {
  if (a.length < 2 || b.length < 2) return 0
  const bgA = getBigrams(a)
  const bgB = getBigrams(b)
  let intersection = 0
  for (const bg of bgA) if (bgB.has(bg)) intersection++
  return (2 * intersection) / (bgA.size + bgB.size)
}

function buscarProdutos(query: string, produtos: ProdutoVarejo[]): SearchResult[] {
  if (!query || query.trim().length < 2) return []
  const q = norm(query)
  const resultMap = new Map<string, SearchResult>()

  for (const p of produtos) {
    const nomeNorm = norm(p.nome_produto)
    let score = 0
    if (nomeNorm === q) score = 4
    else if (nomeNorm.startsWith(q)) score = 3
    else if (nomeNorm.includes(q)) score = 2
    else {
      const sim = bigramSimilarity(q, nomeNorm)
      if (sim > 0.4) score = sim
    }
    if (score > 0) {
      const key = `${p.nome_produto}__${p.uf}__${p.mes}`
      const existing = resultMap.get(key)
      if (!existing || score > existing.score) {
        resultMap.set(key, { produto: p, score })
      }
    }
  }
  return Array.from(resultMap.values())
    .sort(
      (a, b) => b.score - a.score || a.produto.nome_produto.localeCompare(b.produto.nome_produto),
    )
    .slice(0, 12)
}

export function SearchResultsModal({
  query,
  produtos,
  onSelectResult,
  onClose,
  visible,
}: SearchResultsModalProps) {
  const { allIsLoading, allIsError, refetchAll } = useHortifruti()
  const results = useMemo(() => buscarProdutos(query, produtos), [query, produtos])

  const grouped = useMemo(() => {
    const map = new Map<string, SearchResult[]>()
    for (const r of results) {
      const key = r.produto.nome_produto
      const group = map.get(key)
      if (group) {
        group.push(r)
      } else {
        map.set(key, [r])
      }
    }
    return Array.from(map.entries()).slice(0, 5)
  }, [results])

  // Fechar com Escape
  useEffect(() => {
    if (!visible) return
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', handler)
    return () => document.removeEventListener('keydown', handler)
  }, [visible, onClose])

  const hasResults = results.length > 0
  const noResults = query.trim().length >= 2 && !hasResults

  return (
    <AnimatePresence>
      {visible && query.trim().length >= 2 && (
        <>
          <motion.div
            key="search-backdrop"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.15 }}
            className="fixed inset-0 z-[60] bg-on-background/10 backdrop-blur-[2px]"
            onClick={onClose}
          />
          <motion.div
            key="search-modal"
            initial={{ opacity: 0, y: -12, scale: 0.97, x: '-50%' }}
            animate={{ opacity: 1, y: 0, scale: 1, x: '-50%' }}
            exit={{ opacity: 0, y: -8, scale: 0.97, x: '-50%' }}
            transition={{ duration: 0.2, ease: [0.4, 0, 0.2, 1] }}
            className="fixed left-1/2 top-[7.25rem] z-[70] flex w-full max-w-md flex-col gap-3 rounded-3xl border border-outline-variant/60 bg-surface-container-lowest/80 p-4 shadow-[0_8px_32px_rgba(0,0,0,0.18),0_2px_8px_rgba(0,0,0,0.12)] backdrop-blur-xl"
          >
            <div className="flex items-center justify-between px-1">
              <span className="text-sm font-semibold text-on-surface-variant">
                🔍 Resultados para <span className="text-primary">&quot;{query}&quot;</span>
              </span>
              {hasResults && (
                <span className="text-xs text-outline">
                  {results.length} resultado{results.length !== 1 ? 's' : ''}
                </span>
              )}
            </div>

            {allIsLoading ? (
              <div className="flex flex-col items-center gap-3 py-4 text-center text-on-surface-variant">
                <div className="flex w-full flex-col gap-2">
                  <Skeleton className="h-4 w-2/3 rounded-full" />
                  <Skeleton className="h-4 w-full rounded-full" />
                  <Skeleton className="h-4 w-5/6 rounded-full" />
                </div>
                <p className="text-xs text-outline">Buscando no catálogo…</p>
              </div>
            ) : allIsError ? (
              <div className="flex flex-col items-center gap-2 py-4 text-center text-on-surface-variant">
                <span className="text-2xl">⚠️</span>
                <p className="text-sm">Não foi possível carregar o catálogo de alimentos.</p>
                <button
                  onClick={() => void refetchAll()}
                  className="mt-1 inline-flex min-h-[44px] items-center rounded-full border border-primary/40 bg-surface-container px-4 text-xs font-semibold text-primary transition-all duration-150 active:scale-95"
                >
                  Tentar novamente
                </button>
              </div>
            ) : (
              noResults && (
                <div className="flex flex-col items-center gap-2 py-4 text-center text-on-surface-variant">
                  <span className="text-2xl">🌿</span>
                  <p className="text-sm">
                    Nenhum alimento encontrado para <strong>&quot;{query}&quot;</strong>
                  </p>
                  <p className="text-xs text-outline">
                    Tente: &quot;maca&quot;, &quot;cebola&quot;, &quot;tomate&quot;
                  </p>
                </div>
              )
            )}

            <div className="flex flex-col gap-3 overflow-y-auto" style={{ maxHeight: '60vh' }}>
              {grouped.map(([nomeProduto, items]) => (
                <motion.div
                  key={nomeProduto}
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ duration: 0.18 }}
                  className="rounded-2xl border border-outline-variant/40 bg-clay-surface/70 p-3 shadow-[2px_2px_8px_rgba(0,0,0,0.08),-1px_-1px_4px_rgba(255,255,255,0.6)] dark:bg-surface-container/70 dark:shadow-[2px_2px_8px_rgba(0,0,0,0.3)]"
                >
                  <p className="mb-2 text-sm font-semibold text-on-surface">{nomeProduto}</p>
                  <div className="flex flex-wrap gap-2">
                    {items.map((r) => {
                      const { uf, mes } = r.produto
                      const mesIdx = typeof mes === 'number' ? mes - 1 : null
                      const mesAbrev = mesIdx !== null ? (MESES_ABREV[mesIdx] ?? '') : ''
                      const emoji = UF_EMOJI[uf] ?? '📍'
                      return (
                        <button
                          key={`${uf}-${mes}`}
                          onClick={() => onSelectResult(uf, nomeProduto)}
                          className="flex min-w-[4rem] flex-col items-center gap-0.5 rounded-2xl border border-outline-variant/50 bg-surface-container p-2.5 shadow-[2px_2px_6px_rgba(0,0,0,0.1),-1px_-1px_3px_rgba(255,255,255,0.7)] transition-all duration-150 hover:shadow-[3px_3px_10px_rgba(0,0,0,0.15),-2px_-2px_6px_rgba(255,255,255,0.8)] active:scale-95 active:shadow-[inset_2px_2px_5px_rgba(0,0,0,0.12)] dark:bg-surface-container-high dark:shadow-[2px_2px_6px_rgba(0,0,0,0.35)]"
                        >
                          <span className="text-xl leading-none">{emoji}</span>
                          <span className="text-[11px] font-bold text-on-surface">{uf}</span>
                          {mesAbrev && (
                            <span className="text-[9px] font-medium text-on-surface-variant">
                              {mesAbrev}
                            </span>
                          )}
                        </button>
                      )
                    })}
                  </div>
                </motion.div>
              ))}
            </div>

            {hasResults && (
              <p className="px-1 text-center text-xs text-outline">
                Toque em um estado para ver os cards
              </p>
            )}
          </motion.div>
        </>
      )}
    </AnimatePresence>
  )
}
