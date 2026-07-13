'use client'

import { useState, useMemo } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { TrendingUp, Layers, X, Salad, RefreshCw, ChevronLeft, Grid, Table, BarChart3 } from 'lucide-react'
import { useHortifruti } from '@/hooks/useHortifruti'
import { useUfs } from '@/hooks/useUfs'
import { ProductCard } from '@/components/ProductCard'
import { SkeletonCard } from '@/components/SkeletonCard'
import { CategoriesModal } from '@/components/CategoriesModal'
import { ThemeToggle } from '@/components/ThemeToggle'
import { TabelaView } from '@/components/TabelaView'
import { GraficosView } from '@/components/GraficosView'
import { cn } from '@/lib/utils'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'

const MONTHS_SHORT = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']

const STATUS_FILTERS = [
  { value: 'VERDE', label: 'Melhor Época', activeClass: 'bg-sazonal-verde-600 text-white border-sazonal-verde-600', idleClass: 'border-sazonal-verde-600 text-sazonal-verde-600 dark:text-sazonal-verde-400' },
  { value: 'AMARELO', label: 'Preço Normal', activeClass: 'bg-sazonal-amarelo-600 text-white border-sazonal-amarelo-600', idleClass: 'border-sazonal-amarelo-600 text-sazonal-amarelo-600 dark:text-sazonal-amarelo-dark' },
  { value: 'VERMELHO', label: 'Péssima Época', activeClass: 'bg-sazonal-vermelho-600 text-white border-sazonal-vermelho-600', idleClass: 'border-sazonal-vermelho-600 text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400' },
]

type ViewMode = 'cards' | 'tabela' | 'graficos'

const viewTabs: { value: ViewMode; label: string; icon: React.ReactNode }[] = [
  { value: 'cards', label: 'Cards', icon: <Grid size={16} /> },
  { value: 'tabela', label: 'Tabela', icon: <Table size={16} /> },
  { value: 'graficos', label: 'Gráficos', icon: <BarChart3 size={16} /> },
]

export function SupermercadoView() {
  const [selectedUF, setSelectedUF] = useState<string>('SP')
  const [selectedYear, setSelectedYear] = useState<number>(new Date().getFullYear())
  const [selectedMonth, setSelectedMonth] = useState<number | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])
  const [selectedStatus, setSelectedStatus] = useState<string | null>(null)
  const [categoriesOpen, setCategoriesOpen] = useState(false)
  const [viewMode, setViewMode] = useState<ViewMode>('cards')
  const [selectedProduto, setSelectedProduto] = useState<{ nome_produto: string; categoria: string | null; uf: string } | null>(null)

  const { products: produtos, allProducts, isLoading, isError } = useHortifruti(selectedUF, selectedYear, selectedMonth)
  const { data: ufsDisponiveis } = useUfs()

  const ufOptions = useMemo(() => {
    const ufs = ufsDisponiveis ?? ['SP', 'RS', 'PR', 'SC', 'MG', 'RJ', 'ES']
    return ufs.map((u: string) => ({ value: u, label: u === 'BR' ? 'BR (Nacional)' : u }))
  }, [ufsDisponiveis])

  const availableYears = useMemo(() => {
    const years = new Set<number>()
    for (const p of allProducts) {
      if (p.ano) years.add(p.ano)
    }
    return Array.from(years).sort((a, b) => b - a)
  }, [allProducts])

  const displayProducts = useMemo(() => {
    let filtered = produtos
    if (selectedProducts.length > 0) {
      filtered = filtered.filter((p) => selectedProducts.includes(p.nome_produto))
    }
    if (selectedStatus) {
      filtered = filtered.filter((p) => p.status_cor === selectedStatus)
    }
    return filtered
  }, [produtos, selectedProducts, selectedStatus])

  const yearOptions = useMemo(
    () => availableYears.map((y) => ({ value: String(y), label: String(y) })),
    [availableYears],
  )

  const activePills = useMemo(() => {
    const pills: { key: string; label: string; onRemove: () => void }[] = [
      { key: 'uf', label: selectedUF, onRemove: () => setSelectedUF('SP') },
      { key: 'ano', label: String(selectedYear), onRemove: () => setSelectedYear(new Date().getFullYear()) },
    ]
    if (selectedMonth != null) {
      pills.push({
        key: 'mes',
        label: `${MONTHS_SHORT[selectedMonth - 1]}/${selectedYear}`,
        onRemove: () => setSelectedMonth(null),
      })
    }
    if (selectedProducts.length > 0) {
      pills.push({
        key: 'produtos',
        label: `${selectedProducts.length} produto${selectedProducts.length === 1 ? '' : 's'}`,
        onRemove: () => setSelectedProducts([]),
      })
    }
    if (selectedStatus) {
      pills.push({
        key: 'status',
        label: selectedStatus === 'VERDE' ? 'Melhor Época' : selectedStatus === 'AMARELO' ? 'Preço Normal' : 'Péssima Época',
        onRemove: () => setSelectedStatus(null),
      })
    }
    return pills
  }, [selectedUF, selectedYear, selectedMonth, selectedProducts, selectedStatus])

  return (
    <div className="min-h-screen bg-[var(--bg-body)]">
      {/* Header fixo */}
      <header className="sticky top-0 z-40 h-14 border-b border-gray-200 dark:border-gray-700 bg-[var(--bg-header)] backdrop-blur-md">
        <div className="flex h-full items-center justify-between px-4">
          <div className="flex items-center gap-2">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-sazonal-verde-600 text-white" aria-label="Sazonalidade">
              <TrendingUp size={20} />
            </div>
            <div>
              <h1 className="text-sm font-bold text-gray-900 dark:text-gray-100">Sazonalidade</h1>
              <p className="text-[11px] text-gray-500 dark:text-gray-400 leading-tight">Preços de Alimentos — CONAB</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <Button
              onClick={() => setCategoriesOpen(true)}
              variant="green"
              size="icon-lg"
              aria-label="Categorias"
            >
              <Layers size={18} />
            </Button>
          </div>
        </div>
      </header>

      {/* Conteúdo principal */}
      <main className="mx-auto max-w-5xl px-4 py-4">
        {/* Active pills */}
        {activePills.length > 0 && (
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            transition={{ duration: 0.2 }}
            className="flex flex-wrap gap-1.5 mb-4"
          >
            {activePills.map((pill) => (
              <motion.button
                key={pill.key}
                onClick={pill.onRemove}
                initial={{ opacity: 0, scale: 0.9 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.9 }}
                className="inline-flex items-center gap-1 rounded-full bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20 px-2.5 py-1 text-xs font-medium text-sazonal-verde-700 dark:text-sazonal-verde-400 hover:bg-sazonal-verde-100 dark:hover:bg-sazonal-verde-dark/30 transition-colors"
              >
                {pill.label}
                <X size={12} />
              </motion.button>
            ))}
            {activePills.length > 2 && (
              <motion.button
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                onClick={() => { setSelectedMonth(null); setSelectedProducts([]); setSelectedStatus(null) }}
                className="text-xs text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 underline"
              >
                Limpar tudo
              </motion.button>
            )}
          </motion.div>
        )}

        {/* Loading state */}
        {isLoading && (
          <div className="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {[1, 2, 3, 4, 5, 6].map((i) => <SkeletonCard key={i} />)}
          </div>
        )}

        {/* Error state */}
        {isError && !isLoading && (
          <div className="mt-4 rounded-lg border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-900/20 p-4">
            <div className="flex items-center gap-2 text-red-700 dark:text-red-400">
              <RefreshCw size={16} />
              <p className="text-sm font-medium">Erro</p>
            </div>
            <p className="text-sm text-red-600 dark:text-red-300 mt-1">
              Não foi possível carregar os dados. Tente novamente mais tarde.
            </p>
          </div>
        )}

        {/* Empty state */}
        {!isLoading && !isError && allProducts.length === 0 && (
          <div className="flex flex-col items-center justify-center mt-16">
            <Salad size={48} className="text-gray-300 dark:text-gray-600" />
            <h2 className="text-lg font-bold mt-4 text-gray-900 dark:text-gray-100">Nenhum dado disponível</h2>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Ainda não existem dados de sazonalidade registrados pela CONAB.
            </p>
          </div>
        )}

        {/* Data loaded */}
        {!isLoading && !isError && allProducts.length > 0 && (
          <div className="flex flex-col gap-6 mt-4">
            {/* Período — card de seleção */}
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.3 }}
              className="rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4 shadow-sm"
            >
              <div className="flex flex-col gap-3">
                {/* UF + Ano + contagem */}
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <select
                      value={selectedUF}
                      onChange={(e) => { setSelectedUF(e.target.value); setSelectedMonth(null); setSelectedStatus(null); setSelectedProduto(null) }}
                      className="h-9 rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2 text-sm outline-none focus:ring-2 focus:ring-sazonal-verde-600 w-24"
                      aria-label="Selecionar UF"
                    >
                      {ufOptions.map((opt) => (
                        <option key={opt.value} value={opt.value}>{opt.label}</option>
                      ))}
                    </select>
                    <select
                      value={selectedYear}
                      onChange={(e) => { setSelectedYear(Number(e.target.value)); setSelectedMonth(null); setSelectedStatus(null); setSelectedProduto(null) }}
                      className="h-9 rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2 text-sm outline-none focus:ring-2 focus:ring-sazonal-verde-600 w-24"
                      aria-label="Selecionar ano"
                    >
                      {yearOptions.map((opt) => (
                        <option key={opt.value} value={opt.value}>{opt.label}</option>
                      ))}
                    </select>
                  </div>
                  <Badge variant="secondary" className="text-xs">
                    {displayProducts.length} item{displayProducts.length !== 1 ? 'ns' : ''}
                  </Badge>
                </div>

                {/* Grid de meses */}
                <div className="grid grid-cols-4 gap-1.5 sm:grid-cols-6 lg:grid-cols-12">
                  {MONTHS_SHORT.map((name, idx) => {
                    const monthNum = idx + 1
                    const isActive = selectedMonth === monthNum
                    return (
                      <motion.button
                        key={monthNum}
                        onClick={() => { setSelectedMonth(isActive ? null : monthNum); setSelectedProduto(null) }}
                        initial={{ opacity: 0, scale: 0.9 }}
                        animate={{ opacity: 1, scale: 1 }}
                        className={cn(
                          'flex flex-col items-center rounded-md border px-1 py-1.5 text-xs transition-colors min-h-[44px]',
                          isActive
                            ? 'bg-sazonal-verde-600 text-white border-sazonal-verde-600'
                            : 'border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700',
                        )}
                        aria-label={`${name} ${selectedYear}`}
                      >
                        <span className="text-[10px] opacity-70">{String(monthNum).padStart(2, '0')}</span>
                        <span className="text-xs font-bold">{name}</span>
                      </motion.button>
                    )
                  })}
                </div>

                {/* Ações: visão completa + categorias */}
                <div className="flex items-center justify-between">
                  {selectedMonth && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => { setSelectedMonth(null); setSelectedProduto(null) }}
                    >
                      <ChevronLeft size={14} className="mr-1" />
                      Visão Completa
                    </Button>
                  )}
                  <Button
                    onClick={() => setCategoriesOpen(true)}
                    variant="light"
                    size="sm"
                    className={cn(!selectedMonth && 'ml-auto')}
                  >
                    <Layers size={16} className="mr-1" />
                    Categorias
                  </Button>
                </div>
              </div>
            </motion.div>

            {/* Abas de visualização */}
            <Tabs value={viewMode} onValueChange={(v) => setViewMode(v as ViewMode)} className="w-full">
              <TabsList className="grid w-full grid-cols-3">
                {viewTabs.map((tab) => (
                  <TabsTrigger key={tab.value} value={tab.value} className="flex items-center justify-center gap-2">
                    {tab.icon}
                    <span>{tab.label}</span>
                  </TabsTrigger>
                ))}
              </TabsList>

              <AnimatePresence mode="wait">
                {viewMode === 'cards' && (
                  <TabsContent value="cards" className="mt-2">
                    <motion.div
                      initial={{ opacity: 0, y: 20 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -20 }}
                      transition={{ duration: 0.2 }}
                    >
                      <div className="flex flex-col gap-3">
                        {/* Status chips */}
                        <div className="flex flex-wrap gap-1.5">
                          {STATUS_FILTERS.map((f) => (
                            <motion.button
                              key={f.value}
                              onClick={() => setSelectedStatus(selectedStatus === f.value ? null : f.value)}
                              initial={{ scale: 0.9 }}
                              animate={{ scale: 1 }}
                              whileHover={{ scale: 1.02 }}
                              whileTap={{ scale: 0.98 }}
                              className={cn(
                                'rounded-full border px-3 py-1 text-xs font-medium transition-colors',
                                selectedStatus === f.value ? f.activeClass : f.idleClass,
                              )}
                            >
                              {f.label}
                            </motion.button>
                          ))}
                          {selectedStatus && (
                            <motion.button
                              initial={{ scale: 0.9 }}
                              animate={{ scale: 1 }}
                              onClick={() => setSelectedStatus(null)}
                              className="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300"
                              aria-label="Limpar filtro"
                            >
                              <X size={14} />
                            </motion.button>
                          )}
                        </div>

                        {/* Product grid */}
                        {displayProducts.length > 0 ? (
                          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
                            {displayProducts.map((p) => (
                              <motion.div
                                key={p.id_produto}
                                initial={{ opacity: 0, scale: 0.9, y: 20 }}
                                animate={{ opacity: 1, scale: 1, y: 0 }}
                                exit={{ opacity: 0, scale: 0.9 }}
                                transition={{ duration: 0.2, delay: 0.02 }}
                              >
                                <ProductCard
                                  product={p}
                                  isSelected={selectedProducts.includes(p.nome_produto)}
                                  onToggle={() =>
                                    setSelectedProducts((prev) =>
                                      prev.includes(p.nome_produto)
                                        ? prev.filter((x) => x !== p.nome_produto)
                                        : [...prev, p.nome_produto],
                                    )
                                  }
                                />
                              </motion.div>
                            ))}
                          </div>
                        ) : (
                          <div className="flex items-center justify-center py-10">
                            <p className="text-sm text-gray-400">Nenhum produto encontrado para este período.</p>
                          </div>
                        )}
                      </div>
                    </motion.div>
                  </TabsContent>
                )}

                {viewMode === 'tabela' && (
                  <TabsContent value="tabela" className="mt-2">
                    <motion.div
                      initial={{ opacity: 0, y: 20 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -20 }}
                      transition={{ duration: 0.2 }}
                    >
                      <TabelaView
                        uf={selectedUF}
                        ano={selectedMonth ? selectedYear : undefined}
                        mes={selectedMonth ?? undefined}
                        onSelectProduto={(prod) => setSelectedProduto({
                          nome_produto: prod.nome_produto,
                          categoria: prod.categoria,
                          uf: prod.uf,
                        })}
                        selectedProduto={selectedProduto}
                      />
                    </motion.div>
                  </TabsContent>
                )}

                {viewMode === 'graficos' && (
                  <TabsContent value="graficos" className="mt-2">
                    <motion.div
                      initial={{ opacity: 0, y: 20 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -20 }}
                      transition={{ duration: 0.2 }}
                    >
                      <GraficosView
                        uf={selectedUF}
                        ano={selectedMonth ? selectedYear : undefined}
                        mes={selectedMonth ?? undefined}
                        selectedProduto={selectedProduto}
                      />
                    </motion.div>
                  </TabsContent>
                )}
              </AnimatePresence>
            </Tabs>
          </div>
        )}
      </main>

      <CategoriesModal
        open={categoriesOpen}
        onClose={() => setCategoriesOpen(false)}
        produtos={produtos}
        selectedProducts={selectedProducts}
        onToggleProduct={(prod) =>
          setSelectedProducts((prev) =>
            prev.includes(prod) ? prev.filter((p) => p !== prod) : [...prev, prod],
          )
        }
      />
    </div>
  )
}