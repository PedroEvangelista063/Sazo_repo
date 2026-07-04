import { useState, useMemo } from 'react'
import { Calendar, Search, X, Plus, ChevronDown, TrendingUp, Salad, Layers, Filter } from 'lucide-react'
import { useHortifruti } from '../hooks/useHortifruti'
import { ProductCard } from '../components/ProductCard'
import { SkeletonCard } from '../components/SkeletonCard'
import { CategoriesModal } from '../components/CategoriesModal'
import { ThemeToggle } from '../components/ThemeToggle'

const MONTHS_SHORT = ['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez']

const STATUS_FILTERS: { key: string; label: string; bg: string; border: string; text: string; activeBg: string }[] = [
  { key: 'VERDE',  label: 'Melhor Época',  bg: 'bg-green-50',               border: 'border-green-300',               text: 'text-green-700',               activeBg: 'bg-green-500 text-white border-green-600' },
  { key: 'AMARELO', label: 'Preço Normal',  bg: 'bg-yellow-50',              border: 'border-yellow-300',              text: 'text-yellow-700',              activeBg: 'bg-yellow-500 text-white border-yellow-600' },
  { key: 'VERMELHO', label: 'Péssima Época', bg: 'bg-red-50',               border: 'border-red-300',                 text: 'text-red-700',                 activeBg: 'bg-red-500 text-white border-red-600' },
]

interface SupermercadoViewProps {
  isDark: boolean
  onToggleTheme: () => void
}

export function SupermercadoView({ isDark, onToggleTheme }: SupermercadoViewProps) {
  const [selectedYear, setSelectedYear] = useState<number>(new Date().getFullYear())
  const [selectedMonth, setSelectedMonth] = useState<number | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])
  const [selectedStatus, setSelectedStatus] = useState<string | null>(null)
  const [listOpen, setListOpen] = useState(true)
  const [productsOpen, setProductsOpen] = useState(true)
  const [categoriesOpen, setCategoriesOpen] = useState(false)

  const { products: produtos, allProducts, isLoading, isError } = useHortifruti(selectedYear, selectedMonth)

  const { availableYears, monthsByYear } = useMemo(() => {
    const years = new Set<number>()
    const months: Record<number, Set<number>> = {}

    for (const p of allProducts) {
      if (!p.ano) continue
      years.add(p.ano)
      if (!months[p.ano]) months[p.ano] = new Set()
      if (p.mes) months[p.ano].add(p.mes)
    }

    return {
      availableYears: Array.from(years).sort((a, b) => b - a),
      monthsByYear: months,
    }
  }, [allProducts])

  const monthsInYear = useMemo(() => {
    if (!selectedYear) return new Set<number>()
    return monthsByYear[selectedYear] ?? new Set()
  }, [selectedYear, monthsByYear])

  const availableProducts = useMemo(() => {
    const filtered = allProducts.filter((p) => p.ano === selectedYear)
    return Array.from(new Set(filtered.map((p) => p.nome_produto))).sort()
  }, [allProducts, selectedYear])

  const handleYearChange = (year: number) => {
    setSelectedYear(year)
    setSelectedMonth(null)
    setSelectedStatus(null)
  }

  const handleMonthClick = (month: number) => {
    setSelectedMonth((prev) => (prev === month ? null : month))
  }

  const toggleProduct = (produto: string) => {
    setSelectedProducts((prev) =>
      prev.includes(produto)
        ? prev.filter((p) => p !== produto)
        : [...prev, produto],
    )
  }

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

  return (
    <div className="min-h-dvh bg-gradient-to-b from-gray-100 to-white dark:from-gray-900 dark:to-gray-950">
      <header className="sticky top-0 z-40 border-b border-green-100 bg-white/90 shadow-sm backdrop-blur-lg dark:border-gray-800 dark:bg-gray-900/90">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-3">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-emerald-400 dark:bg-emerald-600">
              <TrendingUp className="h-5 w-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold leading-tight text-gray-900 dark:text-gray-100">
                Sazonalidade
              </h1>
              <p className="text-xs text-gray-500 dark:text-gray-400">
                Preços de Alimentos &mdash; CONAB &middot; SP
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <ThemeToggle isDark={isDark} onToggle={onToggleTheme} />
            <button
              onClick={() => setCategoriesOpen(true)}
              className="flex items-center gap-1.5 rounded-xl bg-emerald-400 px-4 py-2 text-xs font-bold text-white shadow-sm transition-colors hover:bg-emerald-500 dark:bg-emerald-600 dark:hover:bg-emerald-500"
            >
              <Layers size={14} />
              Categorias
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-4 pb-12 pt-6">
        {isLoading && (
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {[1, 2, 3, 4, 5, 6].map((i) => (
              <SkeletonCard key={i} />
            ))}
          </div>
        )}

        {isError && !isLoading && (
          <div className="mt-12 rounded-xl border border-red-100 bg-red-50 p-8 text-center dark:border-red-900 dark:bg-red-900/20">
            <p className="font-semibold text-red-600 dark:text-red-400">
              Não foi possível carregar os dados. Tente novamente mais tarde.
            </p>
          </div>
        )}

        {!isLoading && !isError && allProducts.length === 0 && (
          <div className="mt-12 flex flex-col items-center justify-center rounded-2xl border border-dashed border-gray-300 bg-white p-12 text-center shadow-sm dark:border-gray-700 dark:bg-gray-800">
            <div className="mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-green-100 dark:bg-green-900/50">
              <Salad className="h-8 w-8 text-green-600 dark:text-green-400" />
            </div>
            <h3 className="text-xl font-bold text-gray-800 dark:text-gray-200">Nenhum dado disponível</h3>
            <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
              Ainda não existem dados de sazonalidade registrados pela CONAB.
            </p>
          </div>
        )}

        {!isLoading && allProducts.length > 0 && (
          <>
            <div className="mb-6 rounded-2xl border border-green-100 bg-white p-5 shadow-sm dark:border-gray-800 dark:bg-gray-900">
              <div className="mb-4 flex items-center justify-between">
                <h2 className="flex items-center text-sm font-bold uppercase tracking-wider text-gray-700 dark:text-gray-300">
                  <Calendar className="mr-2 h-4 w-4 text-green-600 dark:text-green-400" />
                  Período de Análise
                </h2>
                <div className="relative">
                  <select
                    value={selectedYear}
                    onChange={(e) => handleYearChange(Number(e.target.value))}
                    className="appearance-none rounded-lg border border-gray-200 bg-gray-50 px-4 py-2 pr-8 text-sm font-semibold text-gray-700 outline-none transition-colors hover:border-green-300 focus:border-green-400 focus:ring-2 focus:ring-green-100 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300 dark:hover:border-green-600 dark:focus:border-green-500 dark:focus:ring-green-900"
                  >
                    {availableYears.map((year) => (
                      <option key={year} value={year}>
                        {year}
                      </option>
                    ))}
                  </select>
                  <ChevronDown className="pointer-events-none absolute right-2 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
                </div>
              </div>

              <div className="grid grid-cols-3 gap-2 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-12">
                {MONTHS_SHORT.map((name, idx) => {
                  const monthNum = idx + 1
                  const hasData = monthsInYear.has(monthNum)
                  const isActive = selectedMonth === monthNum

                  return (
                    <button
                      key={monthNum}
                      onClick={() => handleMonthClick(monthNum)}
                      className={`relative flex flex-col items-center justify-center rounded-xl px-2 py-3 text-xs font-bold transition-all ${
                        isActive
                          ? 'bg-emerald-400 text-white shadow-md shadow-emerald-200 dark:bg-emerald-600 dark:shadow-emerald-900/30'
                          : hasData
                            ? 'cursor-pointer border border-green-200 bg-green-50 text-green-700 hover:border-green-300 hover:bg-green-100 dark:border-green-800 dark:bg-green-900/20 dark:text-green-300 dark:hover:border-green-700 dark:hover:bg-green-900/30'
                            : 'cursor-pointer border border-gray-200 bg-gray-50 text-gray-400 hover:border-gray-300 hover:bg-gray-100 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-500 dark:hover:border-gray-600 dark:hover:bg-gray-700'
                      }`}
                    >
                      <span className="text-[10px] opacity-70">{String(monthNum).padStart(2, '0')}</span>
                      <span className="mt-0.5">{name}</span>
                      {hasData && !isActive && (
                        <span className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full border-2 border-white bg-green-400 dark:border-gray-900 dark:bg-green-500" />
                      )}
                    </button>
                  )
                })}
              </div>

              <div className="mt-3 flex items-center gap-4 text-xs text-gray-400 dark:text-gray-500">
                <span className="flex items-center gap-1">
                  <span className="h-2 w-2 rounded-full bg-green-400 dark:bg-green-500" />
                  Com dados
                </span>
                <span className="flex items-center gap-1">
                  <span className="h-2 w-2 rounded-full bg-gray-300 dark:bg-gray-600" />
                  Sem dados
                </span>
                {selectedMonth && (
                  <button
                    onClick={() => setSelectedMonth(null)}
                    className="ml-auto font-semibold text-green-600 hover:text-green-800 dark:text-green-400 dark:hover:text-green-300"
                  >
                    Visão Completa
                  </button>
                )}
              </div>
            </div>

            <div className="mb-6 rounded-2xl border border-gray-100 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-900">
              <button
                onClick={() => setListOpen(!listOpen)}
                className="flex w-full items-center justify-between px-5 py-4 transition-colors hover:bg-gray-50 dark:hover:bg-gray-800"
              >
                <h2 className="flex items-center text-sm font-bold uppercase tracking-wider text-gray-700 dark:text-gray-300">
                  <Search className="mr-2 h-4 w-4 text-green-600 dark:text-green-400" />
                  Monte sua Lista
                </h2>
                <div className="flex items-center gap-3">
                  {selectedProducts.length > 0 && (
                    <span
                      onClick={(e) => { e.stopPropagation(); setSelectedProducts([]) }}
                      className="text-xs font-semibold text-red-400 transition-colors hover:text-red-600 dark:text-red-400 dark:hover:text-red-300"
                    >
                      Limpar ({selectedProducts.length})
                    </span>
                  )}
                  <ChevronDown
                    className={`h-4 w-4 text-gray-400 transition-transform ${listOpen ? '' : '-rotate-90'}`}
                  />
                </div>
              </button>
              {listOpen && (
                <div className="border-t border-gray-100 px-5 pb-5 pt-4 dark:border-gray-800">
                  <div className="flex flex-wrap gap-2">
                    {availableProducts.map((prod) => {
                      const isSelected = selectedProducts.includes(prod)
                      return (
                        <button
                          key={prod}
                          onClick={() => toggleProduct(prod)}
                          className={`flex items-center gap-1.5 rounded-xl border px-3.5 py-2 text-xs font-semibold transition-all ${
                            isSelected
                              ? 'border-green-500 bg-green-50 text-green-700 shadow-sm dark:border-green-600 dark:bg-green-900/30 dark:text-green-300'
                              : 'border-gray-200 bg-gray-50 text-gray-600 hover:border-green-300 hover:text-green-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400 dark:hover:border-green-600 dark:hover:text-green-400'
                          }`}
                        >
                          {prod}
                          {isSelected ? (
                            <X size={12} className="text-green-600 dark:text-green-400" />
                          ) : (
                            <Plus size={12} className="text-gray-400" />
                          )}
                        </button>
                      )
                    })}
                  </div>
                </div>
              )}
            </div>

            <div className="mb-4 rounded-2xl border border-gray-100 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-900">
              <button
                onClick={() => setProductsOpen(!productsOpen)}
                className="flex w-full items-center justify-between px-5 py-4 transition-colors hover:bg-gray-50 dark:hover:bg-gray-800"
              >
                <h2 className="text-base font-bold text-gray-900 dark:text-gray-100">
                  {selectedProducts.length > 0
                    ? 'Produtos Selecionados'
                    : 'Todos os Produtos'}
                </h2>
                <div className="flex items-center gap-3">
                  <span className="rounded-full bg-green-100 px-3 py-1 text-xs font-bold text-green-700 dark:bg-green-900/30 dark:text-green-300">
                    {displayProducts.length} {displayProducts.length === 1 ? 'item' : 'itens'}
                  </span>
                  <ChevronDown
                    className={`h-4 w-4 text-gray-400 transition-transform ${productsOpen ? '' : '-rotate-90'}`}
                  />
                </div>
              </button>
              {productsOpen && (
                <div className="border-t border-gray-100 px-5 pb-5 pt-4 dark:border-gray-800">
                  <div className="mb-4 flex flex-wrap gap-2">
                    {STATUS_FILTERS.map((f) => {
                      const active = selectedStatus === f.key
                      return (
                        <button
                          key={f.key}
                          onClick={() => setSelectedStatus(active ? null : f.key)}
                          className={`flex items-center gap-1.5 rounded-xl border px-3.5 py-2 text-xs font-semibold transition-all ${
                            active
                              ? f.activeBg + ' shadow-sm'
                              : `${f.bg} ${f.border} ${f.text} hover:brightness-95`
                          }`}
                        >
                          <Filter size={12} />
                          {f.label}
                        </button>
                      )
                    })}
                    {selectedStatus && (
                      <button
                        onClick={() => setSelectedStatus(null)}
                        className="flex items-center gap-1.5 rounded-xl border border-gray-200 bg-gray-50 px-3.5 py-2 text-xs font-semibold text-gray-500 transition-all hover:bg-gray-100 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400"
                      >
                        <X size={12} />
                        Limpar
                      </button>
                    )}
                  </div>
                  {displayProducts.length > 0 ? (
                    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
                      {displayProducts.map((p) => (
                        <ProductCard key={p.id_produto} product={p} />
                      ))}
                    </div>
                  ) : (
                    <div className="rounded-xl border border-dashed border-gray-300 bg-gray-50 p-8 text-center dark:border-gray-700 dark:bg-gray-800">
                      <p className="text-sm font-medium text-gray-500 dark:text-gray-400">
                        Nenhum produto encontrado para este período.
                      </p>
                    </div>
                  )}
                </div>
              )}
            </div>
          </>
        )}
      </main>

      <CategoriesModal
        open={categoriesOpen}
        onClose={() => setCategoriesOpen(false)}
        produtos={produtos}
        selectedProducts={selectedProducts}
        onToggleProduct={toggleProduct}
      />
    </div>
  )
}
