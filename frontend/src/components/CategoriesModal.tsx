import { useState, useMemo } from 'react'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from './ui/dialog'
import { Button } from './ui/button'
import { Badge } from './ui/badge'
import { Search, X, ChevronLeft } from 'lucide-react'
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
  const [searchQuery, setSearchQuery] = useState('')

  const produtosPorCategoria = useMemo(() => {
    const map: Record<string, string[]> = {}
    for (const p of produtos) {
      const cat = p.categoria || 'ALIMENTO_VAREJO'
      if (!map[cat]) map[cat] = []
      if (!map[cat].includes(p.nome_produto)) map[cat].push(p.nome_produto)
    }
    return map
  }, [produtos])

  const drillProdutos = useMemo(() => {
    if (!drillCategory) return []
    const raw = produtosPorCategoria[drillCategory] || []
    const sorted = [...raw].sort()
    if (!searchQuery.trim()) return sorted
    const q = searchQuery.trim().toLowerCase()
    return sorted.filter((p) => p.toLowerCase().includes(q))
  }, [drillCategory, produtosPorCategoria, searchQuery])

  const catMap = useMemo(() => {
    const m: Record<string, Categoria> = {}
    for (const c of categorias || []) m[c.nome] = c
    return m
  }, [categorias])

  function handleClose() {
    setDrillCategory(null)
    setSearchQuery('')
    onClose()
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        if (!o) handleClose()
      }}
    >
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {drillCategory ? (
              <div className="flex items-center gap-2">
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={() => {
                    setDrillCategory(null)
                    setSearchQuery('')
                  }}
                  aria-label="Voltar"
                >
                  <ChevronLeft size={16} />
                </Button>
                <span>{drillCategory.replace(/_/g, ' ')}</span>
              </div>
            ) : (
              'Categorias'
            )}
          </DialogTitle>
          <DialogDescription>
            {drillCategory
              ? 'Selecione os produtos para filtrar'
              : 'Escolha uma categoria para explorar os produtos'}
          </DialogDescription>
        </DialogHeader>

        {isLoading && (
          <div className="flex items-center justify-center py-10">
            <div className="h-6 w-6 animate-spin rounded-full border-2 border-sazonal-verde-600 border-t-transparent" />
          </div>
        )}

        {!isLoading && !drillCategory && categorias && (
          <div className="flex flex-col gap-2">
            {categorias.map((cat) => (
              <Button
                key={cat.nome}
                onClick={() => {
                  setDrillCategory(cat.nome)
                  setSearchQuery('')
                }}
                variant="light"
                className="h-auto justify-between rounded-2xl py-3 shadow-clay-btn hover:shadow-clay-btn-hover active:translate-y-[1px] active:shadow-clay-press"
              >
                <span className="flex items-center gap-2">
                  <span className="text-xl">{cat.icone || '📆'}</span>
                  <span className="text-sm font-semibold">{cat.nome.replace(/_/g, ' ')}</span>
                </span>
                <Badge variant="secondary">{cat.total_produtos}</Badge>
              </Button>
            ))}
          </div>
        )}

        {!isLoading && drillCategory && (
          <div className="flex flex-col gap-2">
            <div className="relative mb-1">
              <Search
                size={14}
                className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400"
              />
              <input
                type="text"
                placeholder="Buscar produto..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.currentTarget.value)}
                className="h-9 w-full rounded-clay-sm border border-gray-300 bg-white pl-9 pr-3 text-sm shadow-clay-press outline-none focus:ring-2 focus:ring-sazonal-verde-600 dark:border-gray-600 dark:bg-gray-800"
              />
            </div>
            {catMap[drillCategory]?.descricao && (
              <p className="mb-1 text-xs text-gray-500 dark:text-gray-400">
                {catMap[drillCategory].descricao}
              </p>
            )}
            {drillProdutos.length === 0 ? (
              <p className="py-6 text-center text-sm text-gray-400">
                Nenhum produto disponível nesta categoria
              </p>
            ) : (
              <div className="flex flex-wrap gap-2">
                {drillProdutos.map((prod) => {
                  const isSelected = selectedProducts.includes(prod)
                  return (
                    <button
                      key={prod}
                      onClick={() => onToggleProduct(prod)}
                      className={`inline-flex items-center rounded-full px-3 py-1 text-sm font-medium transition-colors ${
                        isSelected
                          ? 'bg-sazonal-verde-600 text-white shadow-clay-btn'
                          : 'bg-gray-100 text-gray-700 hover:bg-gray-200 hover:shadow-clay-btn-hover dark:bg-gray-700 dark:text-gray-300 dark:hover:bg-gray-600'
                      }`}
                    >
                      {prod}
                      {isSelected && <X size={12} className="ml-1" />}
                    </button>
                  )
                })}
              </div>
            )}
          </div>
        )}

        <p className="pt-2 text-center text-xs text-gray-400">
          {selectedProducts.length > 0
            ? `${selectedProducts.length} produto${selectedProducts.length === 1 ? '' : 's'} na lista`
            : 'Toque nos produtos para adicionar à sua lista'}
        </p>
      </DialogContent>
    </Dialog>
  )
}
