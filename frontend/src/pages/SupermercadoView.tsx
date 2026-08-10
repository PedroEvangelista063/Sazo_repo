'use client'

import { useState, useMemo } from 'react'
import { motion, AnimatePresence } from 'framer-motion'

// Hooks
import { useRegioes } from '@/hooks/useRegioes'
import { useRegiaoResumo } from '@/hooks/useRegiaoResumo'
import { useHortifruti } from '@/hooks/useHortifruti'
import { useUfs } from '@/hooks/useUfs'
import { useFluxos } from '@/hooks/useFluxos'

// Layout Components
import { TopAppBar } from '@/components/layout/TopAppBar'
import { OfflineBanner } from '@/components/layout/OfflineBanner'
import { NavigationTabs } from '@/components/layout/NavigationTabs'
import { Footer } from '@/components/layout/Footer'

// Feature Components
import { BrasilMap } from '@/components/BrasilMap'
import { RegiaoPanel } from '@/components/RegiaoPanel'
import { ProductCard } from '@/components/ProductCard'
import { SkeletonCard } from '@/components/SkeletonCard'
import { CategoriesModal } from '@/components/CategoriesModal'
import { GradeSazonalAcordeao } from '@/components/GradeSazonalAcordeao'
import { useTheme } from '@/hooks/useTheme'

type ViewMode = 'grade-sazonal' | 'cards' | 'mapa'

export function SupermercadoView() {
  const { toggleTheme } = useTheme()
  const [selectedUF, setSelectedUF] = useState<string>('BR')
  const [selectedYear] = useState<number>(() => new Date().getFullYear())
  const [selectedMonth, setSelectedMonth] = useState<number | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])
  const [selectedStatus, setSelectedStatus] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<ViewMode>('grade-sazonal')

  // Modal / Sidebar states
  const [isMonthModalOpen, setIsMonthModalOpen] = useState(false)
  const [categoriesOpen, setCategoriesOpen] = useState(false)
  const [selectedRegion, setSelectedRegion] = useState<string | null>(null)
  const [selectedMapUF, setSelectedMapUF] = useState<string | null>(null)

  // Data fetching
  const { data: regioes } = useRegioes()
  const {
    data: regiaoResumo,
    isLoading: regiaoLoading,
    isError: regiaoError,
  } = useRegiaoResumo(selectedRegion, selectedYear)

  const {
    products: produtos,
    allProducts,
    brSazonalidade,
    totalBR,
    isLoading,
    isError,
  } = useHortifruti(selectedUF, selectedYear, selectedMonth)

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
        const nome = f.item
          .normalize('NFD')
          .replace(/[\u0300-\u036f]/g, '')
          .toUpperCase()
        map.set(nome, f.origem_uf)
      }
    }
    return map
  }, [fluxos])

  const fluxosRegiao = useMemo(() => {
    if (!fluxos) return []
    if (selectedMapUF) {
      return fluxos.filter((f) => f.origem_uf === selectedMapUF || f.destino_uf === selectedMapUF)
    }
    if (!selectedRegion) return []
    const ufs = regioes?.find((r) => r.id === selectedRegion)?.ufs ?? []
    return fluxos.filter((f) => ufs.includes(f.destino_uf) || ufs.some((u) => u === f.origem_uf))
  }, [fluxos, selectedRegion, selectedMapUF, regioes])

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

  const toggleStatusFilter = (status: string) => {
    setSelectedStatus((prev) => (prev === status ? null : status))
  }

  const months = [
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

  return (
    <>
      <div className="opacity-8 pointer-events-none fixed inset-0 z-[-1]"></div>

      <TopAppBar onCalendarClick={() => setIsMonthModalOpen(true)} onThemeToggle={toggleTheme} />

      <OfflineBanner />

      <main className="mx-auto mt-4 flex w-full max-w-7xl flex-col gap-lg px-margin-mobile pb-xl pt-sm md:flex-row">
        {/* Side Navigation Filters */}
        <nav className="hide-scrollbar sticky top-16 z-30 flex h-auto w-full shrink-0 flex-row items-center gap-4 overflow-x-auto rounded-2xl bg-surface-container/90 px-4 py-3 shadow-clay-dark backdrop-blur-md md:top-24 md:h-fit md:w-16 md:flex-col md:overflow-y-auto md:rounded-full md:py-lg">
          <div className="whitespace-nowrap text-center font-label-sm text-[10px] text-secondary md:mb-2 md:mt-4 md:rotate-[-90deg]">
            Filtros
          </div>

          <button
            className={`scroll-snap-align-center flex h-10 w-10 items-center justify-center rounded-full transition-all active:scale-90 ${selectedStatus === 'VERDE' ? 'bg-status-green text-on-primary shadow-clay-green brightness-110' : 'bg-status-green/80 text-on-primary/80 shadow-clay-dark'}`}
            title="Melhor Época"
            onClick={() => toggleStatusFilter('VERDE')}
          >
            <span className="material-symbols-outlined text-[18px]">done</span>
          </button>

          <button
            className={`scroll-snap-align-center flex h-10 w-10 items-center justify-center rounded-full transition-all active:scale-90 ${selectedStatus === 'AMARELO' ? 'bg-status-yellow text-on-secondary-container shadow-clay-pressed brightness-110' : 'bg-status-yellow/80 text-on-secondary-container/80 shadow-clay-dark'}`}
            title="Preço Normal"
            onClick={() => toggleStatusFilter('AMARELO')}
          >
            <span className="material-symbols-outlined text-[18px]">remove</span>
          </button>

          <button
            className={`scroll-snap-align-center flex h-10 w-10 items-center justify-center rounded-full transition-all active:scale-90 ${selectedStatus === 'VERMELHO' ? 'bg-status-red text-on-error shadow-clay-pressed brightness-110' : 'bg-status-red/80 text-on-error/80 shadow-clay-dark'}`}
            title="Péssima Época"
            onClick={() => toggleStatusFilter('VERMELHO')}
          >
            <span className="material-symbols-outlined text-[18px]">close</span>
          </button>

          <button
            className="scroll-snap-align-center clay-card flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-surface-container-lowest text-outline transition-colors hover:bg-surface-bright active:scale-90 md:mb-4 md:mt-auto"
            title="Categorias"
            onClick={() => setCategoriesOpen(true)}
          >
            <span className="material-symbols-outlined text-[18px]">layers</span>
          </button>
        </nav>

        {/* Main Content Area */}
        <div className="w-full flex-1 overflow-hidden">
          <NavigationTabs
            activeTab={viewMode}
            onTabChange={(tab) => setViewMode(tab as ViewMode)}
          />

          <div className="mt-4">
            {/* UF / Ano selectors (Mobile friendly or global context) */}
            <div className="rounded-clay shadow-clay-card mb-4 flex flex-wrap items-center justify-between bg-surface-container-low p-4">
              <div className="flex items-center gap-4">
                <select
                  value={selectedUF}
                  onChange={(e) => {
                    setSelectedUF(e.target.value)
                    setSelectedMonth(null)
                    setSelectedStatus(null)
                  }}
                  className="h-10 rounded-lg border border-outline-variant bg-surface-container px-3 text-on-surface outline-none transition-colors focus:border-primary"
                >
                  {ufOptions.map((opt) => (
                    <option key={opt.value} value={opt.value}>
                      {opt.label}
                    </option>
                  ))}
                </select>
                <span className="font-headline-md text-primary">{selectedYear}</span>
              </div>
              {selectedMonth && (
                <div className="flex items-center gap-2">
                  <span className="rounded-full bg-primary/10 px-3 py-1 font-label-sm text-primary">
                    {months[selectedMonth - 1]}
                  </span>
                  <button
                    onClick={() => setSelectedMonth(null)}
                    className="p-1 text-on-surface-variant transition-colors hover:text-error"
                    title="Limpar mês"
                  >
                    <span className="material-symbols-outlined text-sm">close</span>
                  </button>
                </div>
              )}
            </div>

            {/* Loading & Error States */}
            {isLoading && (
              <div className="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
                {[1, 2, 3, 4, 5, 6].map((i) => (
                  <SkeletonCard key={i} />
                ))}
              </div>
            )}

            {isError && !isLoading && (
              <div className="clay-card mt-4 flex items-center justify-center gap-2 p-4 text-error">
                <span className="material-symbols-outlined">refresh</span>
                <p>Erro ao carregar dados. Tente novamente.</p>
              </div>
            )}

            {!isLoading && !isError && allProducts.length === 0 && !brSazonalidade && (
              <div className="clay-card mt-4 flex flex-col items-center p-10 text-on-surface-variant">
                <span className="material-symbols-outlined mb-2 text-4xl">info</span>
                <p>Nenhum dado disponível.</p>
              </div>
            )}

            {/* Content Tabs */}
            <AnimatePresence mode="wait">
              {viewMode === 'grade-sazonal' && !isLoading && (
                <motion.div
                  key="grade"
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -10 }}
                  transition={{ duration: 0.2 }}
                >
                  {selectedUF === 'BR' && brSazonalidade ? (
                    <div className="clay-card p-4">
                      <div className="mb-4 flex items-center gap-2 text-sm text-on-surface-variant">
                        <span className="material-symbols-outlined text-sm">info</span>
                        Grade sazonal nacional. Exibindo {totalBR} produtos.
                      </div>
                      <GradeSazonalAcordeao data={brSazonalidade} />
                    </div>
                  ) : (
                    <div className="clay-card flex flex-col items-center justify-center gap-4 p-8 text-center">
                      <span className="material-symbols-outlined text-4xl text-outline">
                        table_chart
                      </span>
                      <p className="text-on-surface-variant">
                        Selecione "BR (Nacional)" e remova o filtro de mês para ver a Grade Sazonal.
                      </p>
                      <button
                        className="rounded-full bg-primary px-4 py-2 font-label-sm text-on-primary shadow-clay-green transition-all hover:brightness-110 active:scale-95"
                        onClick={() => {
                          setSelectedUF('BR')
                          setSelectedMonth(null)
                        }}
                      >
                        Ver Grade Nacional
                      </button>
                    </div>
                  )}
                </motion.div>
              )}

              {viewMode === 'cards' && !isLoading && (
                <motion.div
                  key="cards"
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -10 }}
                  transition={{ duration: 0.2 }}
                  className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4"
                >
                  {displayProducts.map((p, i) => (
                    <motion.div
                      key={`${p.id_produto}-${p.uf}-${p.municipio ?? ''}`}
                      initial={{ opacity: 0, scale: 0.9, y: 10 }}
                      animate={{ opacity: 1, scale: 1, y: 0 }}
                      transition={{ duration: 0.2, delay: i * 0.02 }}
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
                          p.nome_produto
                            .normalize('NFD')
                            .replace(/[\u0300-\u036f]/g, '')
                            .toUpperCase(),
                        )}
                      />
                    </motion.div>
                  ))}
                  {displayProducts.length === 0 && (
                    <div className="col-span-full py-10 text-center text-on-surface-variant">
                      Nenhum produto encontrado com os filtros atuais.
                    </div>
                  )}
                </motion.div>
              )}

              {viewMode === 'mapa' && !isLoading && (
                <motion.div
                  key="mapa"
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -10 }}
                  transition={{ duration: 0.2 }}
                  className="flex flex-col gap-lg lg:flex-row"
                >
                  <div className="clay-card relative flex min-h-[400px] flex-1 items-center justify-center overflow-hidden p-lg">
                    <BrasilMap
                      selectedRegion={selectedRegion}
                      onRegionClick={(id) => setSelectedRegion(selectedRegion === id ? null : id)}
                      selectedUF={selectedMapUF}
                      onUfClick={handleUfClick}
                      fluxos={fluxos}
                    />
                    <div className="absolute left-4 top-4 flex items-center gap-2 rounded-full border border-outline-variant bg-surface-container/80 p-2 backdrop-blur-sm">
                      <div className="relative flex h-8 w-8 items-center justify-center rounded-full border border-primary/50 bg-primary/20 text-primary">
                        <span className="material-symbols-outlined text-sm">public</span>
                      </div>
                      <span className="font-label-sm text-label-sm text-on-surface">
                        Visão Interativa
                      </span>
                    </div>
                  </div>

                  <div className="w-full shrink-0 lg:w-80">
                    <RegiaoPanel
                      regiao={regioes?.find((r) => r.id === selectedRegion) ?? null}
                      selectedUF={selectedMapUF}
                      produtos={regiaoResumo?.data ?? []}
                      fluxos={fluxosRegiao}
                      isLoading={regiaoLoading}
                      isError={regiaoError}
                      onClose={() => {
                        setSelectedRegion(null)
                        setSelectedMapUF(null)
                      }}
                      onPoloClick={handlePoloClick}
                    />
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        </div>
      </main>

      <Footer />

      {/* Month Selection Modal */}
      <AnimatePresence>
        {isMonthModalOpen && (
          <div className="fixed inset-0 z-[100] flex items-center justify-center p-margin-mobile">
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="absolute inset-0 bg-on-background/20 backdrop-blur-sm"
              onClick={() => setIsMonthModalOpen(false)}
            />
            <motion.div
              initial={{ opacity: 0, scale: 0.95, y: 20 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 20 }}
              className="relative flex w-full max-w-md flex-col gap-lg rounded-lg bg-surface-container-lowest/90 p-lg shadow-clay-dark backdrop-blur-md"
            >
              <div className="flex items-center justify-between">
                <h2 className="font-headline-md text-headline-md text-on-surface">
                  Selecionar Mês
                </h2>
                <button
                  className="clay-card rounded-full p-2 text-outline transition-all hover:text-primary active:scale-90"
                  onClick={() => setIsMonthModalOpen(false)}
                >
                  <span className="material-symbols-outlined">close</span>
                </button>
              </div>
              <div className="grid grid-cols-3 gap-md">
                {months.map((month, idx) => {
                  const monthNum = idx + 1
                  const isSelected = selectedMonth === monthNum
                  return (
                    <button
                      key={month}
                      onClick={() => {
                        setSelectedMonth(isSelected ? null : monthNum)
                        setIsMonthModalOpen(false)
                      }}
                      className={`clay-card rounded-lg p-md font-label-sm transition-all hover:scale-105 ${
                        isSelected
                          ? 'border border-primary/50 bg-primary text-on-primary shadow-clay-green'
                          : 'text-on-surface-variant'
                      }`}
                    >
                      {month}
                    </button>
                  )
                })}
              </div>
            </motion.div>
          </div>
        )}
      </AnimatePresence>

      {/* Categories Modal */}
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
    </>
  )
}
