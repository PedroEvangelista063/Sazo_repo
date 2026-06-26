import { MapPin, RotateCcw } from 'lucide-react'
import { useUserStore } from '../store/useUserStore'
import { useSazonalidade } from '../hooks/useSazonalidade'
import { ProductCard, ProductCardSkeleton } from '../components/ProductCard'
import { LocationSelector } from '../components/LocationSelector'

export function Dashboard() {
  const { uf, municipio, clearLocation } = useUserStore()
  const hasLocation = !!uf && !!municipio
  const { products, isLoading } = useSazonalidade(uf, municipio)

  if (!hasLocation) {
    return (
      <main className="mx-auto flex min-h-dvh max-w-lg flex-col justify-center px-6 py-12">
        <LocationSelector />
      </main>
    )
  }

  return (
    <main className="mx-auto min-h-dvh max-w-4xl px-4 py-4 pb-24">
      <header className="mb-4 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-bold text-gray-900">Quero Comprar</h1>
          <span className="flex items-center gap-1 text-xs text-gray-500">
            <MapPin className="h-3 w-3" />
            {municipio} / {uf}
          </span>
        </div>
        <button
          onClick={clearLocation}
          className="flex items-center gap-1 rounded-lg px-3 py-2 text-xs font-medium text-gray-500 transition-colors hover:bg-gray-100 hover:text-gray-700"
        >
          <RotateCcw className="h-3.5 w-3.5" />
          Alterar
        </button>
      </header>

      {isLoading ? (
        <section className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-4">
          {Array.from({ length: 8 }).map((_, i) => (
            <ProductCardSkeleton key={i} />
          ))}
        </section>
      ) : products.length === 0 ? (
        <div className="mt-16 text-center text-gray-400">
          <p className="text-sm">Nenhum produto encontrado para esta região.</p>
        </div>
      ) : (
        <section className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-4">
          {products.map((product) => (
            <ProductCard key={product.id_produto} product={product} />
          ))}
        </section>
      )}
    </main>
  )
}
