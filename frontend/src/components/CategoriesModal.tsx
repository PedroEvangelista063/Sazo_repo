import { useState, useMemo } from 'react'
import { X, ChevronRight, Check, Plus, Layers, Search } from 'lucide-react'
import { useCategorias } from '../hooks/useCategorias'
import type { Categoria, ProdutoVarejo } from '../types/domain'

interface CategoriesModalProps {
  open: boolean
  onClose: () => void
  produtos: ProdutoVarejo[]
  selectedProducts: string[]
  onToggleProduct: (product: string) => void
}

export function CategoriesModal({
  open,
  onClose,
  produtos,
  selectedProducts,
  onToggleProduct,
}: CategoriesModalProps) {
  const { data: categorias, isLoading } = useCategorias()
  const [drillCategory, setDrillCategory] = useState<string | null>(null)

  const produtosPorCategoria = useMemo(() => {
    const map: Record<string, string[]> = {}
    for (const p of produtos) {
      const cat = p.categoria || 'ALOMENTO_VAREJO'
      if (!map[cat]) map[cat] = []
      if (!map[cat].includes(p.nome_produto)) map[cat].push(p.nome_produto)
    }
    return map
  }, [produtos])

  const drillProdutos = drillCategory ? (produtosPorCategoria[drillCategory] || []).sort() : []

  const catMap = useMemo(() => {
    const m: Record<string, Categoria> = {}
    for (const c of categorias || []) m[c.nome] = c
    return m
  }, [categorias])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center">
      <div className="absolute inset-0 bg-black/30" onClick={onClose} />

      <div
        className="relative w-full max-w-lg rounded-2xl border border-white/20 p-6 shadow-2xl sm:mx-4 sm:max-h-[80vh] sm:overflow-y-auto"
        style={{
          background: 'linear-gradient(135deg, rgba(255,255,255,0.25), rgba(255,255,255,0.05))',
          backdropFilter: 'blur(20px)',
          WebkitBackdropFilter: 'blur(20px)',
          border: '1px solid rgba(255,255,255,0.18)',
          boxShadow: '0 8px 32px 0 rgba(31, 38, 135, 0.15)',
        }}
      >
        <div className="mb-5 flex items-center justify-between">
          <div className="flex items-center gap-2">
            {drillCategory ? (
              <button
                onClick={() => { setDrillCategory(null) }}
                className="text-sm font-semibold text-green-700 hover:text-green-600"
              >
                Voltar
              </button>
            ) : (
              <Layers className="h-5 w-5 text-green-600" />
            )}
            <h2 className="text-lg font-bold text-gray-900">
              {drillCategory ? (drillCategory.replace(/_/g, ' ')) : 'Categorias'}
            </h2>
          </div>
          <button
            onClick={onClose}
            className="flex h-8 w-8 items-center justify-center rounded-full bg-white/40 text-gray-600 hover:bg-white/60"
          >
            <X size={18} />
          </button>
        </div>

        {isLoading && (
          <div className="flex items-center justify-center py-12">
            <div className="h-8 w-8 animate-spin rounded-full border-4 border-green-300 border-t-green-600" />
          </div>
        )}

        {!isLoading && !drillCategory && categorias && (
          <div className="space-y-2">
            {categorias.map((cat) => (
              <button
                key={cat.nome}
                onClick={() => setDrillCategory(cat.nome)}
                className="flex w-full items-center gap-3 rounded-xl bg-white/40 px-4 py-3.5 text-left transition-all hover:bg-white/60"
              >
                <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-white/60 text-xl shadow-sm">
                  {cat.icone || '📆'}
                </span>
                <div className="flex-1">
                  <p className="text-sm font-bold text-gray-900">
                    {cat.nome.replace(/_/g, ' ')}
                  </p>
                  <p className="line-clamp-1 text-xs text-gray-500">
                    {cat.descricao || `${cat.total_produtos} produtos`}
                  </p>
                </div>
                <span className="rounded-full bg-white/50 px-2.5 py-0.5 text-xs font-bold text-green-700">
                  {cat.total_produtos}
                </span>
                <ChevronRight size={16} className="text-gray-400" />
              </button>
            ))}
          </div>
        )}

        {!isLoading && drillCategory && (
          <div>
            {catMap[drillCategory] && (
              <p className="mb-3 text-xs text-gray-500">
                {catMap[drillCategory].descricao}
              </p>
            )}

            {drillProdutos.length === 0 && (
              <div className="flex flex-col items-center justify-center py-10 text-gray-400">
                <Search size={32} className="mb-2 opacity-50" />
                <p className="text-sm">Nenhum produto disponivel nesta categoria</p>
              </div>
            )}

            <div className="space-y-1">
              {drillProdutos.map((prod) => {
                const isSelected = selectedProducts.includes(prod)
                return (
                  <button
                    key={prod}
                    onClick={() => onToggleProduct(prod)}
                    className={`flex w-full items-center gap-3 rounded-xl px-4 py-2.5 text-left transition-all ${
                      isSelected
                        ? 'bg-green-500/20'
                        : 'bg-white/30 hover:bg-white/50'
                    }`}
                  >
                    <span
                      className={`flex h-8 w-8 items-center justify-center rounded-lg text-sm font-bold ${
                        isSelected
                          ? 'bg-green-500 text-white'
                          : 'bg-white/60 text-gray-600'
                      }`}
                    >
                      {isSelected ? <Check size={14} /> : <Plus size={14} />}
                    </span>
                    <span className="flex-1 text-sm font-medium text-gray-800">
                      {prod}
                    </span>
                  </button>
                )
              })}
            </div>
          </div>
        )}

        <div className="mt-4 rounded-xl bg-white/40 px-4 py-3 text-center">
          <p className="text-xs text-gray-500">
            {selectedProducts.length > 0
              ? `${selectedProducts.length} produto${selectedProducts.length === 1 ? '' : 's'} na lista`
              : 'Toque nos produtos para adicionar a sua lista'}
          </p>
        </div>
      </div>
    </div>
  )
}
