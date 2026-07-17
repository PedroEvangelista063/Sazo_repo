'use client'

import { useState, useMemo, useRef, useEffect } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { TrendingUp, Layers, X, Salad, RefreshCw, ChevronLeft, Grid, MapPin } from 'lucide-react'
import { BrasilMap } from '@/components/BrasilMap'
import { RegiaoPanel } from '@/components/RegiaoPanel'
import { useRegioes } from '@/hooks/useRegioes'
import { useRegiaoResumo } from '@/hooks/useRegiaoResumo'
import { useHortifruti } from '@/hooks/useHortifruti'
import { useUfs } from '@/hooks/useUfs'
import { useFluxos } from '@/hooks/useFluxos'
import { ProductCard } from '@/components/ProductCard'
import { SkeletonCard } from '@/components/SkeletonCard'
import { CategoriesModal } from '@/components/CategoriesModal'
import { ThemeToggle } from '@/components/ThemeToggle'
import { SazonalidadeNacional } from '@/components/SazonalidadeNacional'
import { BRNationalIcon } from '@/components/BRNationalIcon'
import { cn } from '@/lib/utils'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import Beams from '@/components/Beams'
import BlurText from '@/components/BlurText'

const MONTHS_SHORT = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']

const STATUS_FILTERS = [
  { value: 'VERDE', label: 'Melhor Época', activeClass: 'bg-sazonal-verde-600 text-white border-sazonal-verde-600', idleClass: 'border-sazonal-verde-600 text-sazonal-verde-600 dark:text-sazonal-verde-400' },
  { value: 'AMARELO', label: 'Preço Normal', activeClass: 'bg-sazonal-amarelo-600 text-white border-sazonal-amarelo-600', idleClass: 'border-sazonal-amarelo-600 text-sazonal-amarelo-600 dark:text-sazonal-amarelo-dark' },
  { value: 'VERMELHO', label: 'Péssima Época', activeClass: 'bg-sazonal-vermelho-600 text-white border-sazonal-vermelho-600', idleClass: 'border-sazonal-vermelho-600 text-sazonal-vermelho-600 dark:text-sazonal-vermelho-400' },
]

type ViewMode = 'grade-sazonal' | 'mapa' | 'cards'

const viewTabs: { value: ViewMode; label: string; icon: React.ReactNode }[] = [
  { value: 'grade-sazonal', label: 'Grade Sazonal', icon: <Grid size={16} /> },
  { value: 'mapa', label: 'Mapa Regional', icon: <MapPin size={16} /> },
  { value: 'cards', label: 'Cards', icon: <Layers size={16} /> },
]

export function SupermercadoView() {
  const [selectedUF, setSelectedUF] = useState<string>('SP')
  const [selectedYear, setSelectedYear] = useState<number>(new Date().getFullYear())
  const [selectedMonth, setSelectedMonth] = useState<number | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])
  const [selectedStatus, setSelectedStatus] = useState<string | null>(null)
  const [categoriesOpen, setCategoriesOpen] = useState(false)
  const [viewMode, setViewMode] = useState<ViewMode>('cards')
  const [selectedRegion, setSelectedRegion] = useState<string | null>(null)
  const [selectedMapUF, setSelectedMapUF] = useState<string | null>(null)
  const headerRef = useRef<HTMLDivElement>(null)

  // Auto-seleciona BR quando entra na Grade Sazonal
  useEffect(() => {
    if (viewMode === 'grade-sazonal') {
      setSelectedUF('BR')
    }
  }, [viewMode])
  const { data: regioes } = useRegioes()
  const { data: regiaoResumo, isLoading: regiaoLoading, isError: regiaoError } = useRegiaoResumo(selectedRegion, selectedYear)

  const { products: produtos, allProducts, brSazonalidade, totalBR, isLoading, isError } = useHortifruti(selectedUF, selectedYear, selectedMonth)
  const { data: ufsDisponiveis } = useUfs()
  const { data: fluxos } = useFluxos()

  const ufOptions = useMemo(() => {
    const ufs = ufsDisponiveis ?? ['SP', 'RS', 'PR', 'SC', 'MG', 'RJ', 'ES']
    return ufs.map((u: string) => ({ value: u, label: u === 'BR' ? 'BR (Nacional)' : u }))
  }, [ufsDisponiveis])

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

  const origemPorProduto = useMemo(() => {
    const map = new Map<string, string>()
    if (!fluxos) return map
    for (const f of fluxos) {
      if (!map.has(f.item)) {
        const nome = f.item.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase()
        map.set(nome, f.origem_uf)
      }
    }
    return map
  }, [fluxos])

  const fluxosRegiao = useMemo(() => {
    if (!fluxos) return []
    // Se uma UF específica está selecionada no mapa, filtra por ela
    if (selectedMapUF) {
      return fluxos.filter(
        (f) => f.origem_uf === selectedMapUF || f.destino_uf === selectedMapUF,
      )
    }
    if (!selectedRegion) return []
    const ufs = regioes?.find((r) => r.id === selectedRegion)?.ufs ?? []
    return fluxos.filter((f) => ufs.includes(f.destino_uf) || ufs.some((u) => u === f.origem_uf))
  }, [fluxos, selectedRegion, selectedMapUF, regioes])

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

  const handlePoloClick = (uf: string) => {
    setSelectedUF(uf)
    setSelectedRegion(null)
    setViewMode('cards')
    setSelectedMonth(null)
  }

  const handleUfClick = (uf: string) => {
    setSelectedMapUF(selectedMapUF === uf ? null : uf)
    setSelectedRegion(null)
  }

  return (
    <div className="relative min-h-screen bg-[var(--bg-body)] overflow-hidden">
      {/* Beams background decorativo */}
      <div className="fixed inset-0 z-0 opacity-[0.08] dark:opacity-[0.04] pointer-events-none">
        <Beams
          beamWidth={1.5}
          beamHeight={12}
          beamNumber={8}
          lightColor="#16a34a"
          speed={1.5}
          noiseIntensity={1.2}
          scale={0.15}
          rotation={25}
        />
      </div>

      {/* Header fixo */}
      <header
        ref={headerRef}
        className="sticky top-0 z-40 h-14 border-b border-gray-200/80 dark:border-gray-700/80 bg-[var(--bg-header)] backdrop-blur-xl shadow-sm"
      >
        <div className="flex h-full items-center justify-between px-4">
          <div className="flex items-center gap-2">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-sazonal-verde-600 text-white shadow-md" aria-label="Sazonalidade">
              <TrendingUp size={20} />
            </div>
            <div>
              <h1 className="text-sm font-bold text-gray-900 dark:text-gray-100">
                Sazonalidade
              </h1>
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
              className="shadow-sm"
            >
              <Layers size={18} />
            </Button>
          </div>
        </div>
      </header>

      {/* Conteúdo principal */}
      <main className="relative z-10 mx-auto max-w-5xl px-4 py-4">
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
                className="inline-flex items-center gap-1 rounded-full bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20 px-2.5 py-1 text-xs font-medium text-sazonal-verde-700 dark:text-sazonal-verde-400 hover:bg-sazonal-verde-100 dark:hover:bg-sazonal-verde-dark/30 transition-colors shadow-sm"
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
          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            className="mt-4 rounded-xl border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-900/20 p-4 shadow-sm"
          >
            <div className="flex items-center gap-2 text-red-700 dark:text-red-400">
              <RefreshCw size={16} />
              <p className="text-sm font-medium">Erro ao carregar dados</p>
            </div>
            <p className="text-sm text-red-600 dark:text-red-300 mt-1">
              Não foi possível carregar os dados. Tente novamente mais tarde.
            </p>
          </motion.div>
        )}

        {/* Empty state */}
        {!isLoading && !isError && allProducts.length === 0 && !brSazonalidade && (
          <div className="flex flex-col items-center justify-center mt-16">
            <Salad size={48} className="text-gray-300 dark:text-gray-600" />
            <BlurText
              text="Nenhum dado disponível"
              className="text-lg font-bold mt-4 text-gray-900 dark:text-gray-100"
              delay={80}
              direction="top"
              animateBy="words"
            />
            <p className="text-sm text-gray-500 dark:text-gray-400 mt-2">
              Ainda não existem dados de sazonalidade registrados pela CONAB.
            </p>
          </div>
        )}

        {/* Data loaded */}
        {!isLoading && !isError && (allProducts.length > 0 || brSazonalidade != null) && (
          <div className="flex flex-col gap-6 mt-4">
            {/* Período — card de seleção */}
            <motion.div
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.3 }}
              className="rounded-xl border border-gray-200 dark:border-gray-700 bg-white/90 dark:bg-gray-800/90 backdrop-blur-sm p-4 shadow-lg"
            >
              <div className="flex flex-col gap-3">
                {/* UF + Ano + contagem */}
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    {viewMode === 'cards' ? (
                      <select
                        value={selectedUF}
                        onChange={(e) => { setSelectedUF(e.target.value); setSelectedMonth(null); setSelectedStatus(null) }}
                        className="h-9 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2 text-sm outline-none focus:ring-2 focus:ring-sazonal-verde-600 w-24 shadow-sm"
                        aria-label="Selecionar UF"
                      >
                        {ufOptions.map((opt) => (
                          <option key={opt.value} value={opt.value}>{opt.label}</option>
                        ))}
                      </select>
                    ) : (
                      <BRNationalIcon
                        onClick={() => setSelectedUF('BR')}
                        isActive={selectedUF === 'BR'}
                      />
                    )}
                    <span className="text-sm font-semibold text-gray-700 dark:text-gray-300">
                      {selectedYear}
                    </span>
                  </div>
                  <Badge variant="secondary" className="text-xs shadow-sm">
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
                        onClick={() => { setSelectedMonth(isActive ? null : monthNum) }}
                        initial={{ opacity: 0, scale: 0.9 }}
                        animate={{ opacity: 1, scale: 1 }}
                        transition={{ delay: idx * 0.02 }}
                        className={cn(
                          'flex flex-col items-center rounded-lg border px-1 py-1.5 text-xs transition-all duration-150 min-h-[44px]',
                          isActive
                            ? 'bg-sazonal-verde-600 text-white border-sazonal-verde-600 shadow-md shadow-sazonal-verde-600/20'
                            : 'border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 hover:shadow-sm',
                        )}
                        whileHover={!isActive ? { y: -2 } : {}}
                        whileTap={{ scale: 0.95 }}
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
                      onClick={() => { setSelectedMonth(null) }}
                    >
                      <ChevronLeft size={14} className="mr-1" />
                      Visão Completa
                    </Button>
                  )}
                  <Button
                    onClick={() => setCategoriesOpen(true)}
                    variant="light"
                    size="sm"
                    className={cn(!selectedMonth && 'ml-auto', 'shadow-sm')}
                  >
                    <Layers size={16} className="mr-1" />
                    Categorias
                  </Button>
                </div>
              </div>
            </motion.div>

            {/* Abas de visualização */}
            <Tabs value={viewMode} onValueChange={(v) => setViewMode(v as ViewMode)} className="w-full">
              <TabsList className="grid w-full grid-cols-3 shadow-sm">
                {viewTabs.map((tab) => (
                  <TabsTrigger key={tab.value} value={tab.value} className="flex items-center justify-center gap-2">
                    {tab.icon}
                    <span>{tab.label}</span>
                  </TabsTrigger>
                ))}
              </TabsList>

              <AnimatePresence mode="wait">
                {viewMode === 'grade-sazonal' && (
                  <TabsContent value="grade-sazonal" className="mt-2">
                    <motion.div
                      initial={{ opacity: 0, y: 20 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -20 }}
                      transition={{ duration: 0.2 }}
                    >
                      {selectedUF === 'BR' && selectedMonth == null && brSazonalidade ? (
                        <div>
                          <div className="flex items-center gap-2 mb-3">
                            <Badge variant="secondary" className="text-xs shadow-sm">
                              {totalBR} produtos
                            </Badge>
                            <span className="text-xs text-gray-400">Grade sazonal {selectedYear}</span>
                          </div>
                          <SazonalidadeNacional data={brSazonalidade} />
                        </div>
                      ) : (
                        <div className="flex items-center justify-center py-10">
                          <p className="text-sm text-gray-400">
                            Selecione BR (Nacional) sem filtro de mês para ver a grade sazonal.
                          </p>
                        </div>
                      )}
                    </motion.div>
                  </TabsContent>
                )}

                {viewMode === 'mapa' && (
                  <TabsContent value="mapa" className="mt-2">
                    <motion.div
                      initial={{ opacity: 0, y: 20 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: -20 }}
                      transition={{ duration: 0.2 }}
                    >
                      <div className="flex flex-col lg:flex-row gap-4">
                        <motion.div
                          className="flex-1 flex justify-center"
                          initial={{ opacity: 0, x: -20 }}
                          animate={{ opacity: 1, x: 0 }}
                          transition={{ duration: 0.3, delay: 0.1 }}
                        >
                          <BrasilMap
                            selectedRegion={selectedRegion}
                            onRegionClick={(id) =>
                              setSelectedRegion(selectedRegion === id ? null : id)
                            }
                            selectedUF={selectedMapUF}
                            onUfClick={handleUfClick}
                            fluxos={fluxos}
                          />
                        </motion.div>
                        <motion.div
                          className="w-full lg:w-80 shrink-0"
                          initial={{ opacity: 0, x: 20 }}
                          animate={{ opacity: 1, x: 0 }}
                          transition={{ duration: 0.3, delay: 0.15 }}
                        >
                          <RegiaoPanel
                            regiao={regioes?.find((r) => r.id === selectedRegion) ?? null}
                            selectedUF={selectedMapUF}
                            produtos={regiaoResumo?.data ?? []}
                            fluxos={fluxosRegiao}
                            isLoading={regiaoLoading}
                            isError={regiaoError}
                            onClose={() => { setSelectedRegion(null); setSelectedMapUF(null) }}
                            onPoloClick={handlePoloClick}
                          />
                        </motion.div>
                      </div>
                    </motion.div>
                  </TabsContent>
                )}

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
                              whileHover={{ scale: 1.05 }}
                              whileTap={{ scale: 0.95 }}
                              className={cn(
                                'rounded-full border px-3 py-1 text-xs font-medium transition-all duration-150 shadow-sm',
                                selectedStatus === f.value ? f.activeClass : f.idleClass + ' hover:shadow-md',
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
                              className="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 p-1"
                              whileHover={{ scale: 1.2 }}
                              aria-label="Limpar filtro"
                            >
                              <X size={14} />
                            </motion.button>
                          )}
                        </div>

                        {displayProducts.length > 0 ? (
                          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
                            {displayProducts.map((p, i) => (
                              <motion.div
                                key={p.id_produto}
                                initial={{ opacity: 0, scale: 0.9, y: 20 }}
                                animate={{ opacity: 1, scale: 1, y: 0 }}
                                exit={{ opacity: 0, scale: 0.9 }}
                                transition={{ duration: 0.2, delay: i * 0.025 }}
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
                                  origemUf={origemPorProduto.get(
                                    p.nome_produto.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase(),
                                  )}
                                />
                              </motion.div>
                            ))}
                          </div>
                        ) : selectedUF === 'BR' && selectedMonth == null ? (
                          <div className="flex items-center justify-center py-10">
                            <p className="text-sm text-gray-400">
                              Use a aba "Grade Sazonal" para visualizar BR Nacional.
                            </p>
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
