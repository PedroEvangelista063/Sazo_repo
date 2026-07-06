import { useState, useMemo } from 'react'
import { Modal, ScrollArea, Stack, Group, Text, TextInput, Badge, Button, Chip, Loader, Center } from '@mantine/core'
import { Search } from 'lucide-react'
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

  return (
    <Modal
      opened={open}
      onClose={() => { setDrillCategory(null); setSearchQuery(''); onClose() }}
      title={drillCategory ? drillCategory.replace(/_/g, ' ') : 'Categorias'}
      size="lg"
      scrollAreaComponent={ScrollArea.Autosize}
    >
      {isLoading && (
        <Center py="xl">
          <Loader color="green" />
        </Center>
      )}

      {!isLoading && !drillCategory && categorias && (
        <Stack gap="xs">
          {categorias.map((cat) => (
            <Button
              key={cat.nome}
              onClick={() => { setDrillCategory(cat.nome); setSearchQuery('') }}
              variant="light"
              color="gray"
              fullWidth
              justify="space-between"
              leftSection={<Text fz={20}>{cat.icone || '📆'}</Text>}
              rightSection={
                <Group gap={4}>
                  <Badge size="sm" variant="light" color="green">{cat.total_produtos}</Badge>
                </Group>
              }
              styles={{ inner: { justifyContent: 'flex-start' } }}
            >
              <Text fw={600} size="sm">{cat.nome.replace(/_/g, ' ')}</Text>
            </Button>
          ))}
        </Stack>
      )}

      {!isLoading && drillCategory && (
        <Stack gap={4}>
          <TextInput
            placeholder="Buscar produto..."
            leftSection={<Search size={14} />}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.currentTarget.value)}
            size="sm"
            mb="xs"
          />
          {catMap[drillCategory]?.descricao && (
            <Text size="xs" c="dimmed" mb="sm">{catMap[drillCategory].descricao}</Text>
          )}
          {drillProdutos.length === 0 ? (
            <Text ta="center" py="xl" c="dimmed" size="sm">Nenhum produto disponível nesta categoria</Text>
          ) : (
            <Chip.Group multiple value={selectedProducts} onChange={() => {}}>
              <Group gap={6}>
                {drillProdutos.map((prod) => (
                  <Chip
                    key={prod}
                    value={prod}
                    onClick={() => onToggleProduct(prod)}
                    checked={selectedProducts.includes(prod)}
                    size="sm"
                    radius="xl"
                  >
                    {prod}
                  </Chip>
                ))}
              </Group>
            </Chip.Group>
          )}
        </Stack>
      )}

      <Text ta="center" size="xs" c="dimmed" py="sm">
        {selectedProducts.length > 0
          ? `${selectedProducts.length} produto${selectedProducts.length === 1 ? '' : 's'} na lista`
          : 'Toque nos produtos para adicionar à sua lista'}
      </Text>
    </Modal>
  )
}
