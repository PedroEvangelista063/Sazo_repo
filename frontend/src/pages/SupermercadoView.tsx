'use client'

import { useState, useMemo, useEffect, useRef, useCallback, type ChangeEvent } from 'react'
import { motion, AnimatePresence } from 'framer-motion'

// Hooks
import { useRegioes } from '@/hooks/useRegioes'
import { useRegiaoResumo } from '@/hooks/useRegiaoResumo'
import { useHortifruti } from '@/hooks/useHortifruti'
import { useUfs } from '@/hooks/useUfs'
import { useFluxos } from '@/hooks/useFluxos'
import { useFluxosBoletins } from '@/hooks/useFluxosBoletins'
import { hapticLight, hapticSuccess } from '@/utils/haptics'
import { temGradeCompleta } from '@/utils/gradeCompleta'
import { normalizarStatusCor } from '@/utils/statusCor'

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
import { SearchResultsModal } from '@/components/SearchResultsModal'
import { cn } from '@/lib/utils'

type ViewMode = 'tabela' | 'cards' | 'mapa'

const PAGE_SIZE = 20

const MESES_NOME = [
  'Janeiro',
  'Fevereiro',
  'Março',
  'Abril',
  'Maio',
  'Junho',
  'Julho',
  'Agosto',
  'Setembro',
  'Outubro',
  'Novembro',
  'Dezembro',
]

const NOME_UF: Record<string, string> = {
  AC: 'Acre',
  AL: 'Alagoas',
  AP: 'Amapá',
  AM: 'Amazonas',
  BA: 'Bahia',
  CE: 'Ceará',
  DF: 'Distrito Federal',
  ES: 'Espírito Santo',
  GO: 'Goiás',
  MA: 'Maranhão',
  MT: 'Mato Grosso',
  MS: 'Mato Grosso do Sul',
  MG: 'Minas Gerais',
  PA: 'Pará',
  PB: 'Paraíba',
  PR: 'Paraná',
  PE: 'Pernambuco',
  PI: 'Piauí',
  RJ: 'Rio de Janeiro',
  RN: 'Rio Grande do Norte',
  RS: 'Rio Grande do Sul',
  RO: 'Rondônia',
  RR: 'Roraima',
  SC: 'Santa Catarina',
  SP: 'São Paulo',
  SE: 'Sergipe',
  TO: 'Tocantins',
}

const STATUS_CHIPS: Record<string, string> = {
  VERDE: 'Barato',
  AMARELO: 'Normal',
  VERMELHO: 'Caro',
}

const CHIP_ATIVO: Record<string, string> = {
  VERDE: 'bg-status-green text-white shadow-clay-pressed',
  AMARELO: 'bg-status-yellow text-on-secondary-container shadow-clay-pressed',
  VERMELHO: 'bg-status-red text-white shadow-clay-pressed',
}

const STATUS_ADJETIVO: Record<string, string> = {
  VERDE: 'baratos',
  AMARELO: 'de preço normal',
  VERMELHO: 'caros',
}

function normalizeBusca(s: string): string {
  return s
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
}

export function SupermercadoView() {
  const [selectedUF, setSelectedUF] = useState<string>('SP')
  const [selectedYear] = useState<number>(() => new Date().getFullYear())
  const [selectedMonth, setSelectedMonth] = useState<number | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])

  // Referência estável para preservar o React.memo do ProductCard
  const handleToggle = useCallback((nomeProduto: string) => {
    setSelectedProducts((prev) =>
      prev.includes(nomeProduto) ? prev.filter((x) => x !== nomeProduto) : [...prev, nomeProduto],
    )
  }, [])
  const [selectedStatus, setSelectedStatus] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<ViewMode>('mapa')
  const [search, setSearch] = useState('')

  // Modal / Sidebar states
  const [isMonthModalOpen, setIsMonthModalOpen] = useState(false)
  const [categoriesOpen, setCategoriesOpen] = useState(false)
  const [searchModalOpen, setSearchModalOpen] = useState(false)
  const [selectedRegion, setSelectedRegion] = useState<string | null>(null)
  const [selectedMapUF, setSelectedMapUF] = useState<string | null>(null)

  // Paginação híbrida (lote 20 + Carregar mais) sobre dados já obtidos
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE)
  const prevVisibleCountRef = useRef(visibleCount)
  useEffect(() => {
    if (visibleCount > prevVisibleCountRef.current) hapticSuccess()
    prevVisibleCountRef.current = visibleCount
  }, [visibleCount])

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
    isLoading,
    isError,
  } = useHortifruti(selectedUF, selectedYear, selectedMonth)

  const { data: ufsDisponiveis } = useUfs()
  const { data: fluxos } = useFluxos()

  const { data: boletins } = useFluxosBoletins({ limit: 200 })
  const boletimFlows = useMemo(() => boletins?.data ?? [], [boletins])

  // Quality Gate de grade (regra de apresentação): a grade BR Nacional exibe
  // SOMENTE produtos cujos dados cobrem os 12 meses. Produtos com gap
  // (ex: Carapau com 2 meses, Abiu com 11) são ocultados. O filtro é feito
  // aqui, na derivação dos itens exibidos, para que contador, acordeão e
  // contagens internas reflitam apenas os produtos completos.
  const brSazonalidadeCompleta = useMemo(
    () => (brSazonalidade ?? []).filter(temGradeCompleta),
    [brSazonalidade],
  )

  const ufLabel =
    selectedUF === 'BR' ? 'BR (Nacional)' : `${selectedUF} (${NOME_UF[selectedUF] ?? selectedUF})`

  const ufOptions = useMemo(() => {
    const base = ufsDisponiveis ?? ['SP', 'RS', 'PR', 'SC', 'MG', 'RJ', 'ES']
    // Remove 'BR' das opções — seleção nacional é feita pelo botão 🇧🇷 no mapa
    const filtered = base.filter((u: string) => u !== 'BR')
    return filtered.map((u: string) => ({
      value: u,
      label: `📍 ${u} (${NOME_UF[u] ?? u})`,
    }))
  }, [ufsDisponiveis])

  // Filtro de busca + lista de produtos selecionados (antes do status)
  const searchFiltered = useMemo(() => {
    let filtered = produtos
    const q = normalizeBusca(search)
    if (q) filtered = filtered.filter((p) => normalizeBusca(p.nome_produto).includes(q))
    if (selectedProducts.length > 0) {
      filtered = filtered.filter((p) => selectedProducts.includes(p.nome_produto))
    }
    return filtered
  }, [produtos, search, selectedProducts])

  const displayProducts = useMemo(() => {
    if (!selectedStatus) return searchFiltered
    const alvo = normalizarStatusCor(selectedStatus)
    return searchFiltered.filter((p) => normalizarStatusCor(p.status_cor) === alvo)
  }, [searchFiltered, selectedStatus])

  const paginatedProducts = useMemo(
    () => displayProducts.slice(0, visibleCount),
    [displayProducts, visibleCount],
  )
  const remaining = Math.max(0, displayProducts.length - visibleCount)

  // Reinicia a paginação sempre que busca/filtro/UF muda
  useEffect(() => {
    setVisibleCount(PAGE_SIZE)
  }, [search, selectedStatus, selectedMonth, selectedUF, selectedProducts])

  // Transição suave (dim) ao trocar mês/UF — sem limpar a tela para branco
  const [isDimming, setIsDimming] = useState(false)
  useEffect(() => {
    if (selectedMonth !== null || selectedUF !== 'BR') {
      setIsDimming(true)
      const t = setTimeout(() => setIsDimming(false), 250)
      return () => clearTimeout(t)
    }
    setIsDimming(false)
  }, [selectedMonth, selectedUF])

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
    hapticLight()
    setSelectedUF(uf)
    setSelectedRegion(null)
    setViewMode('cards')
    setSelectedMonth(null)
  }

  const handleUfClick = (uf: string) => {
    hapticLight()
    setSelectedMapUF(selectedMapUF === uf ? null : uf)
    setSelectedRegion(null)
  }

  const toggleStatusFilter = (status: string) => {
    hapticLight()
    setSelectedStatus((prev) => (prev === status ? null : status))
  }

  const handleTabChange = (tab: string) => {
    hapticLight()
    // Pilar 6: Grade Sazonal exige BR — transiciona a UF automaticamente,
    // mantendo fluxo contínuo (sem erro/banner de ação).
    if (tab === 'tabela' && selectedUF !== 'BR') {
      setSelectedUF('BR')
      setSelectedMonth(null)
    }
    setViewMode(tab as ViewMode)
  }

  const handleUfChange = (e: ChangeEvent<HTMLSelectElement>) => {
    hapticLight()
    setSelectedUF(e.target.value)
    setSelectedMonth(null)
    setSelectedStatus(null)
  }

  const handleMonthChange = (e: ChangeEvent<HTMLSelectElement>) => {
    hapticLight()
    const v = e.target.value
    setSelectedMonth(v ? Number(v) : null)
    setIsMonthModalOpen(false)
  }

  const handleClearSearch = () => {
    hapticLight()
    setSearch('')
  }

  const handleSearchResultSelect = useCallback((uf: string, nomeProduto: string) => {
    hapticSuccess()
    setSearch('')
    setSearchModalOpen(false)
    setSelectedUF(uf)
    setSelectedProducts([nomeProduto])
    setSelectedMonth(null)
    setSelectedStatus(null)
    setViewMode('cards')
  }, [])

  const limparFiltros = () => {
    hapticLight()
    setSearch('')
    setSelectedStatus(null)
    setSelectedMonth(null)
    setSelectedProducts([])
    setVisibleCount(PAGE_SIZE)
  }

  const handleLoadMore = () => {
    hapticLight()
    setVisibleCount((c) => Math.min(c + PAGE_SIZE, displayProducts.length))
  }

  // Confirmation buzz once a fetched batch of data lands (loading → loaded),
  // not on every interaction. Mirrors the old "Carregar Mais" completion point.
  const wasLoadingRef = useRef(false)
  useEffect(() => {
    if (wasLoadingRef.current && !isLoading) {
      hapticSuccess()
    }
    wasLoadingRef.current = isLoading
  }, [isLoading])

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

  const temFiltroAtivo =
    search.length > 0 ||
    selectedStatus !== null ||
    selectedMonth !== null ||
    selectedProducts.length > 0

  const feedbackStatus = selectedStatus ? ` ${STATUS_ADJETIVO[selectedStatus] ?? 'alimentos'}` : ''
  const feedbackMonth = selectedMonth ? ` para o mês de ${MESES_NOME[selectedMonth - 1]}` : ''
  const feedbackMensagem = `Exibindo ${displayProducts.length} alimentos${feedbackStatus} em ${ufLabel}${feedbackMonth}.`

  return (
    <>
      <TopAppBar
        search={search}
        onSearchChange={(val) => {
          setSearch(val)
          setSearchModalOpen(val.trim().length >= 2)
        }}
        onClearSearch={() => {
          handleClearSearch()
          setSearchModalOpen(false)
        }}
        onCalendarClick={() => setIsMonthModalOpen(true)}
      />

      <SearchResultsModal
        query={search}
        produtos={allProducts}
        onSelectResult={handleSearchResultSelect}
        onClose={() => setSearchModalOpen(false)}
        visible={searchModalOpen}
      />

      <OfflineBanner />

      <main className="mx-auto flex w-full max-w-7xl flex-col gap-lg px-margin-mobile pb-[7rem] pt-[7.5rem]">
        {/* Abas + selects — superfície clay */}
        <div className="flex flex-col gap-4 rounded-3xl bg-clay-surface p-3 pb-4 shadow-clay-rest dark:bg-surface-container-low dark:shadow-clay-dark">
          <div className="flex flex-wrap items-center gap-2">
            <NavigationTabs activeTab={viewMode} onTabChange={handleTabChange} />

            {/* Select UF inline com as abas */}
            <div className="relative">
              <select
                value={selectedUF}
                onChange={handleUfChange}
                aria-label="Selecionar UF"
                className="flex min-h-[48px] shrink-0 appearance-none items-center justify-center whitespace-nowrap rounded-full bg-clay-surface py-0 pl-4 pr-10 text-base font-semibold text-on-surface-variant shadow-clay-rest transition-all duration-150 hover:shadow-clay-pressed focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 active:scale-95 dark:bg-surface-container dark:text-on-surface-variant dark:shadow-clay-dark dark:hover:bg-surface-container-high"
              >
                {ufOptions.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <svg
                className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-on-surface-variant"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth={2.5}
              >
                <path d="M6 9l6 6 6-6" />
              </svg>
            </div>

            {/* Select Mês inline com as abas */}
            <div className="relative">
              <select
                value={selectedMonth ?? ''}
                onChange={handleMonthChange}
                aria-label="Selecionar mês"
                className="flex min-h-[48px] shrink-0 appearance-none items-center justify-center whitespace-nowrap rounded-full bg-clay-surface py-0 pl-4 pr-10 text-base font-semibold text-on-surface-variant shadow-clay-rest transition-all duration-150 hover:shadow-clay-pressed focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 active:scale-95 dark:bg-surface-container dark:text-on-surface-variant dark:shadow-clay-dark dark:hover:bg-surface-container-high"
              >
                <option value="">📅 Mês: Todos</option>
                {MESES_NOME.map((nome, idx) => (
                  <option key={nome} value={idx + 1}>
                    📅 Mês: {nome}
                  </option>
                ))}
              </select>
              <svg
                className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-on-surface-variant"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth={2.5}
              >
                <path d="M6 9l6 6 6-6" />
              </svg>
            </div>
          </div>
        </div>

        {/* Filtros horizontais roláveis (chips 48px + seletores) */}
        <div className="flex flex-col gap-2">
          <div className="hide-scrollbar flex items-center gap-2 overflow-x-auto pb-1">
            {(['VERDE', 'AMARELO', 'VERMELHO'] as const).map((status) => {
              const active = selectedStatus === status
              return (
                <button
                  key={status}
                  type="button"
                  onClick={() => toggleStatusFilter(status)}
                  aria-pressed={active}
                  className={cn(
                    'flex h-12 shrink-0 items-center gap-1.5 rounded-full px-3 text-sm font-semibold transition-all duration-150 active:scale-95',
                    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50',
                    active
                      ? CHIP_ATIVO[status]
                      : 'bg-clay-surface text-on-surface-variant shadow-clay-rest hover:shadow-clay-pressed dark:bg-surface-container dark:shadow-clay-dark',
                  )}
                >
                  {STATUS_CHIPS[status]}
                </button>
              )
            })}

            <button
              type="button"
              onClick={() => {
                hapticLight()
                setCategoriesOpen(true)
              }}
              className="flex h-12 shrink-0 items-center gap-1.5 rounded-full bg-clay-surface px-3 text-sm font-semibold text-on-surface-variant shadow-clay-rest transition-all duration-150 hover:shadow-clay-pressed active:scale-95 dark:bg-surface-container dark:shadow-clay-dark"
            >
              🗂️ Categorias
            </button>
          </div>

          {/* Micro-feedback + Limpar Filtros */}
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-on-surface-variant">
            <span>{feedbackMensagem}</span>
            {temFiltroAtivo && (
              <button
                type="button"
                onClick={limparFiltros}
                className="inline-flex min-h-[44px] items-center px-1 font-semibold text-primary underline underline-offset-2 transition-colors hover:text-primary/80"
              >
                Limpar Filtros
              </button>
            )}
          </div>
        </div>

        {/* Loading & Error States */}
        {isLoading && (
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {[1, 2, 3, 4, 5, 6].map((i) => (
              <SkeletonCard key={i} />
            ))}
          </div>
        )}

        {isError && !isLoading && (
          <div className="clay-card flex items-center justify-center gap-2 p-4 text-error">
            <span className="material-symbols-outlined">refresh</span>
            <p>Erro ao carregar dados. Tente novamente.</p>
          </div>
        )}

        {!isLoading && !isError && allProducts.length === 0 && !brSazonalidade && (
          <div className="clay-card flex flex-col items-center p-10 text-on-surface-variant">
            <span className="material-symbols-outlined mb-2 text-4xl">info</span>
            <p>Nenhum dado disponível.</p>
          </div>
        )}

        {/* Conteúdo das abas (dim ao trocar filtro, sem tela branca) */}
        <div
          className={cn(
            'transition-opacity duration-200',
            isDimming ? 'opacity-50' : 'opacity-100',
          )}
        >
          <AnimatePresence mode="wait">
            {viewMode === 'tabela' && !isLoading && (
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
                      Grade sazonal nacional. Exibindo {brSazonalidadeCompleta.length} produtos.
                    </div>
                    <GradeSazonalAcordeao data={brSazonalidadeCompleta} />
                  </div>
                ) : (
                  <div className="clay-card flex flex-col items-center justify-center gap-3 p-8 text-center text-on-surface-variant">
                    <span className="material-symbols-outlined text-4xl text-outline">
                      table_chart
                    </span>
                    <p>Grade sazonal nacional indisponível para a seleção atual.</p>
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
                {paginatedProducts.map((p, i) => (
                  <motion.div
                    key={`${p.id_produto}-${p.uf}-${p.municipio ?? ''}`}
                    initial={{ opacity: 0, scale: 0.9, y: 10 }}
                    animate={{ opacity: 1, scale: 1, y: 0 }}
                    transition={{ duration: 0.2, delay: i * 0.02 }}
                  >
                    <ProductCard
                      product={p}
                      isSelected={selectedProducts.includes(p.nome_produto)}
                      onToggle={handleToggle}
                      origemUf={origemPorProduto.get(
                        p.nome_produto
                          .normalize('NFD')
                          .replace(/[\u0300-\u036f]/g, '')
                          .toUpperCase(),
                      )}
                    />
                  </motion.div>
                ))}
                {paginatedProducts.length === 0 && (
                  <div className="col-span-full py-10 text-center text-on-surface-variant">
                    Nenhum alimento encontrado com os filtros atuais.
                  </div>
                )}
                {remaining > 0 && (
                  <div className="col-span-full flex justify-center pt-2">
                    <button
                      type="button"
                      onClick={handleLoadMore}
                      className="flex min-h-12 items-center gap-2 rounded-full bg-clay-surface px-5 text-sm font-semibold text-on-surface shadow-clay-rest transition-all duration-150 hover:shadow-clay-pressed active:scale-95 dark:bg-surface-container dark:shadow-clay-dark"
                    >
                      📥 Carregar mais 20 alimentos (Restam {remaining})
                    </button>
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
                className="flex flex-col gap-lg"
              >
                <div className="relative w-full overflow-hidden rounded-2xl">
                  <BrasilMap
                    selectedRegion={selectedRegion}
                    onRegionClick={(id) => {
                      hapticLight()
                      setSelectedRegion(selectedRegion === id ? null : id)
                    }}
                    selectedUF={selectedMapUF}
                    onUfClick={handleUfClick}
                    fluxos={fluxos}
                    boletimFlows={boletimFlows}
                    onUfNavigate={handlePoloClick}
                    onTableNavigate={() => {
                      hapticLight()
                      setViewMode('tabela')
                      setSelectedUF('BR')
                    }}
                  />
                </div>

                <div className="w-full">
                  <RegiaoPanel
                    regiao={regioes?.find((r) => r.id === selectedRegion) ?? null}
                    selectedUF={selectedMapUF}
                    produtos={regiaoResumo?.data ?? []}
                    fluxos={fluxosRegiao}
                    boletimFlows={boletimFlows}
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
                  className="clay-card flex h-11 w-11 items-center justify-center rounded-full text-outline transition-all hover:text-primary active:scale-90"
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
                        hapticLight()
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
