import { useState, useMemo, useEffect } from 'react'
import { MapPin, Home, Plus, X, Calendar, Search } from 'lucide-react'
import { useUserStore } from '../store/useUserStore'
import { useHortifruti } from '../hooks/useHortifruti'
import { ProductCard } from '../components/ProductCard'
import { SkeletonCard } from '../components/SkeletonCard'
import { LocationModal } from '../components/LocationModal'

const formatMonth = (dateStr: string) => {
  if (!dateStr) return 'Atual'
  try {
    const [year, month] = dateStr.split('-')
    const months = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']
    return `${months[parseInt(month, 10) - 1]}/${year}`
  } catch {
    return dateStr
  }
}

export function SupermercadoView() {
  const { uf, municipio, clearLocation, isOnboarded } = useUserStore()
  const [changingCity, setChangingCity] = useState(false)
  const [selectedMonth, setSelectedMonth] = useState<string | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])

  const { products: produtos, isLoading, isError } = useHortifruti(uf, municipio)

  const availableMonths = useMemo(() => {
    const months = produtos.map((p) => p.data_referencia_atual).filter(Boolean)
    return Array.from(new Set(months)).sort().reverse()
  }, [produtos])

  const availableProducts = useMemo(() => {
    const names = produtos.map((p) => p.nome_produto)
    return Array.from(new Set(names)).sort()
  }, [produtos])

  useEffect(() => {
    if (availableMonths.length > 0 && !selectedMonth) {
      setSelectedMonth(availableMonths[0])
    }
  }, [availableMonths, selectedMonth])

  const toggleProduct = (produto: string) => {
    setSelectedProducts((prev) =>
      prev.includes(produto)
        ? prev.filter((p) => p !== produto)
        : [...prev, produto],
    )
  }

  const displayProducts = useMemo(() => {
    let filtered = produtos

    if (selectedMonth) {
      filtered = filtered.filter((p) => p.data_referencia_atual === selectedMonth)
    }

    if (selectedProducts.length > 0) {
      filtered = filtered.filter((p) => selectedProducts.includes(p.nome_produto))
    }

    const orderMap: Record<string, number> = {
      VERDE: 1, AMARELO: 2, VERMELHO: 3, INSUFICIENTE: 4,
    }
    return [...filtered].sort(
      (a, b) => (orderMap[a.status_cor] || 99) - (orderMap[b.status_cor] || 99),
    )
  }, [produtos, selectedMonth, selectedProducts])

  if (!isOnboarded || !uf || !municipio) {
    return <LocationModal />
  }

  if (changingCity) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
        <LocationModal />
      </div>
    )
  }

  return (
    <div className="min-h-dvh bg-gray-50">
      <header className="sticky top-0 z-40 border-b border-gray-200 bg-white/80 shadow-sm backdrop-blur-lg">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-3">
          <div className="flex items-center gap-2">
            <MapPin className="h-5 w-5 text-green-600" />
            <div>
              <p className="text-xs font-medium text-gray-500">Sua Feira em</p>
              <p className="text-sm font-bold text-gray-900">
                {municipio} - {uf}
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setChangingCity(true)}
              className="rounded-full bg-gray-100 px-4 py-2 text-sm font-semibold text-gray-700 transition-colors hover:bg-gray-200"
            >
              Trocar
            </button>
            <button
              onClick={() => clearLocation()}
              className="flex h-9 w-9 items-center justify-center rounded-full bg-gray-100 text-gray-700 transition-colors hover:bg-gray-200"
              aria-label="Início"
            >
              <Home size={18} />
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-4 pt-6">
        {isLoading && (
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
            {[1, 2, 3, 4, 5, 6].map((i) => (
              <SkeletonCard key={i} />
            ))}
          </div>
        )}

        {isError && !isLoading && (
          <div className="mt-12 rounded-xl border border-red-100 bg-red-50 p-6 text-center">
            <p className="font-medium text-red-600">
              Ops! Não conseguimos carregar os dados da feira.
            </p>
          </div>
        )}

        {!isLoading && !isError && produtos.length === 0 && (
          <div className="mt-12 flex flex-col items-center justify-center rounded-2xl border border-dashed border-gray-300 bg-white p-10 text-center shadow-sm">
            <div className="mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-gray-100 text-3xl">
              🛒
            </div>
            <h3 className="text-xl font-bold text-gray-800">Prateleira Vazia</h3>
            <p className="mt-2 max-w-sm text-sm text-gray-500">
              Ainda não existem dados de sazonalidade registrados pela CONAB
              para os alimentos na região de{' '}
              <strong>
                {municipio}-{uf}
              </strong>
              .
            </p>
          </div>
        )}

        {!isLoading && produtos.length > 0 && (
          <>
            <div className="mb-6 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm">
              <h2 className="mb-3 flex items-center text-sm font-bold uppercase tracking-wider text-gray-700">
                <Calendar className="mr-2 text-green-600" size={18} />{' '}
                Período de Pesquisa
              </h2>
              <div className="flex gap-2 overflow-x-auto pb-2 scrollbar-hide">
                {availableMonths.map((month) => (
                  <button
                    key={month}
                    onClick={() => setSelectedMonth(month)}
                    className={`whitespace-nowrap rounded-xl px-5 py-2 text-sm font-bold transition-all ${
                      selectedMonth === month
                        ? 'bg-green-500 text-white shadow-md shadow-green-200'
                        : 'border border-gray-200 bg-gray-50 text-gray-600 hover:border-green-300 hover:bg-green-50'
                    }`}
                  >
                    {formatMonth(month)}
                  </button>
                ))}
              </div>
            </div>

            <div className="mb-8 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm">
              <div className="mb-3 flex items-center justify-between">
                <h2 className="flex items-center text-sm font-bold uppercase tracking-wider text-gray-700">
                  <Search className="mr-2 text-green-600" size={18} />{' '}
                  Monte sua Lista
                </h2>
                {selectedProducts.length > 0 && (
                  <button
                    onClick={() => setSelectedProducts([])}
                    className="text-xs font-semibold text-red-500 hover:text-red-700"
                  >
                    Limpar
                  </button>
                )}
              </div>
              <div className="flex flex-wrap gap-2">
                {availableProducts.map((prod) => {
                  const isSelected = selectedProducts.includes(prod)
                  return (
                    <button
                      key={prod}
                      onClick={() => toggleProduct(prod)}
                      className={`flex items-center gap-2 rounded-xl border px-4 py-2 text-sm font-medium transition-all ${
                        isSelected
                          ? 'border-green-500 bg-green-50 text-green-800 shadow-sm'
                          : 'border-gray-200 bg-gray-50 text-gray-600 hover:border-green-300'
                      }`}
                    >
                      {prod}
                      {isSelected ? (
                        <X size={14} className="text-green-700" />
                      ) : (
                        <Plus size={14} className="text-gray-400" />
                      )}
                    </button>
                  )
                })}
              </div>
            </div>

            <div className="mb-4">
              <h2 className="mb-4 text-lg font-bold text-gray-900">
                {selectedProducts.length > 0
                  ? 'Resultado da sua lista'
                  : 'Todos os produtos em oferta'}
              </h2>

              {displayProducts.length > 0 ? (
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
                  {displayProducts.map((p) => (
                    <ProductCard key={p.id_produto} product={p} />
                  ))}
                </div>
              ) : (
                <div className="rounded-xl border border-dashed border-gray-300 bg-gray-50 p-8 text-center">
                  <p className="text-sm font-medium text-gray-500">
                    Nenhum produto cadastrado para este mês específico.
                  </p>
                </div>
              )}
            </div>
          </>
        )}
      </main>
    </div>
  )
}
