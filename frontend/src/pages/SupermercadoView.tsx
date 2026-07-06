import { useState, useMemo } from 'react'
import {
  AppShell, Group, Stack, Title, Text, Select, Button, SimpleGrid,
  Chip, Badge, Alert, Center, ActionIcon, Card,
} from '@mantine/core'
import { TrendingUp, Layers, X, Salad, RefreshCw } from 'lucide-react'
import { useHortifruti } from '../hooks/useHortifruti'
import { useUfs } from '../hooks/useUfs'
import { ProductCard } from '../components/ProductCard'
import { SkeletonCard } from '../components/SkeletonCard'
import { CategoriesModal } from '../components/CategoriesModal'
import { ThemeToggle } from '../components/ThemeToggle'

const MONTHS_SHORT = ['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez']

const STATUS_FILTERS = [
  { value: 'VERDE', label: 'Melhor Época', color: 'green' as const },
  { value: 'AMARELO', label: 'Preço Normal', color: 'yellow' as const },
  { value: 'VERMELHO', label: 'Péssima Época', color: 'red' as const },
]

export function SupermercadoView() {
  const [selectedUF, setSelectedUF] = useState<string>('SP')
  const [selectedYear, setSelectedYear] = useState<number>(new Date().getFullYear())
  const [selectedMonth, setSelectedMonth] = useState<number | null>(null)
  const [selectedProducts, setSelectedProducts] = useState<string[]>([])
  const [selectedStatus, setSelectedStatus] = useState<string | null>(null)
  const [categoriesOpen, setCategoriesOpen] = useState(false)

  const { products: produtos, allProducts, isLoading, isError } = useHortifruti(selectedUF, selectedYear, selectedMonth)
  const { data: ufsDisponiveis } = useUfs()

  const ufOptions = useMemo(() => {
    const ufs = ufsDisponiveis ?? ['SP', 'RS', 'PR', 'SC', 'MG', 'RJ', 'ES']
    return ufs.map((u: string) => ({ value: u, label: u }))
  }, [ufsDisponiveis])

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
    <AppShell header={{ height: 60 }} padding="md">
      <AppShell.Header>
        <Group h="100%" px="md" justify="space-between">
          <Group gap="xs">
            <ActionIcon variant="filled" color="green" size="lg" radius="md" aria-label="Sazonalidade">
              <TrendingUp size={20} />
            </ActionIcon>
            <div>
              <Title order={1} size="h5">Sazonalidade</Title>
              <Text size="xs" c="dimmed">Preços de Alimentos — CONAB</Text>
            </div>
          </Group>
          <Group gap="xs">
            <ThemeToggle />
            <ActionIcon
              onClick={() => setCategoriesOpen(true)}
              variant="filled"
              color="green"
              size="lg"
              radius="md"
              aria-label="Categorias"
            >
              <Layers size={18} />
            </ActionIcon>
          </Group>
        </Group>
      </AppShell.Header>

      <AppShell.Main>
        {activePills.length > 0 && (
          <Group gap={6} mb="md" mt={0}>
            {activePills.map((pill) => (
              <Button
                key={pill.key}
                size="compact-xs"
                variant="light"
                color="green"
                rightSection={<X size={12} />}
                onClick={pill.onRemove}
              >
                {pill.label}
              </Button>
            ))}
            {activePills.length > 2 && (
              <Button
                size="compact-xs"
                variant="subtle"
                color="gray"
                onClick={() => {
                  setSelectedMonth(null)
                  setSelectedProducts([])
                  setSelectedStatus(null)
                }}
              >
                Limpar tudo
              </Button>
            )}
          </Group>
        )}

        {isLoading && (
          <SimpleGrid cols={{ base: 2, sm: 3, lg: 4 }} spacing="md" mt="md">
            {[1, 2, 3, 4, 5, 6].map((i) => <SkeletonCard key={i} />)}
          </SimpleGrid>
        )}

        {isError && !isLoading && (
          <Alert variant="light" color="red" title="Erro" mt="md" icon={<RefreshCw size={16} />}>
            Não foi possível carregar os dados. Tente novamente mais tarde.
          </Alert>
        )}

        {!isLoading && !isError && allProducts.length === 0 && (
          <Center mt="xl" style={{ flexDirection: 'column' }}>
            <Salad size={48} />
            <Title order={3} mt="md">Nenhum dado disponível</Title>
            <Text c="dimmed" size="sm">Ainda não existem dados de sazonalidade registrados pela CONAB.</Text>
          </Center>
        )}

        {!isLoading && allProducts.length > 0 && (
          <Stack gap="lg" mt="md">
            {/* Período — destaque principal */}
            <Card withBorder padding="md" radius="lg" shadow="sm">
              <Stack gap="sm">
                <Group justify="space-between">
                  <Group gap="xs">
                    <Select
                      data={ufOptions}
                      value={selectedUF}
                      onChange={(v) => {
                        if (!v) return
                        setSelectedUF(v)
                        setSelectedMonth(null)
                        setSelectedStatus(null)
                      }}
                      size="sm"
                      w={90}
                      aria-label="Selecionar UF"
                    />
                    <Select
                      data={yearOptions}
                      value={String(selectedYear)}
                      onChange={(v) => {
                        if (!v) return
                        setSelectedYear(Number(v))
                        setSelectedMonth(null)
                        setSelectedStatus(null)
                      }}
                      size="sm"
                      w={100}
                      aria-label="Selecionar ano"
                    />
                  </Group>
                  <Group gap="xs">
                    <Badge size="lg" variant="light" color="green">
                      {displayProducts.length} item{displayProducts.length !== 1 ? 'ns' : ''}
                    </Badge>
                  </Group>
                </Group>

                <SimpleGrid cols={{ base: 4, sm: 6, lg: 12 }} spacing={6}>
                  {MONTHS_SHORT.map((name, idx) => {
                    const monthNum = idx + 1
                    const hasData = monthsInYear.has(monthNum)
                    const isActive = selectedMonth === monthNum
                    return (
                      <Button
                        key={monthNum}
                        onClick={() => setSelectedMonth(isActive ? null : monthNum)}
                        variant={isActive ? 'filled' : hasData ? 'light' : 'default'}
                        color={isActive ? 'green' : hasData ? 'green' : 'gray'}
                        size="sm"
                        styles={{ inner: { flexDirection: 'column', gap: 0 } }}
                        style={{ minHeight: 44 }}
                        aria-label={`${name} ${selectedYear}`}
                      >
                        <Text fz={10} opacity={0.7}>{String(monthNum).padStart(2, '0')}</Text>
                        <Text fz={12} fw={700}>{name}</Text>
                      </Button>
                    )
                  })}
                </SimpleGrid>

                <Group justify="space-between">
                  {selectedMonth && (
                    <Button
                      variant="subtle"
                      color="green"
                      size="compact-sm"
                      onClick={() => setSelectedMonth(null)}
                      leftSection={<X size={14} />}
                    >
                      Visão Completa
                    </Button>
                  )}
                  <Button
                    onClick={() => setCategoriesOpen(true)}
                    variant="light"
                    color="green"
                    size="sm"
                    leftSection={<Layers size={16} />}
                    ml="auto"
                  >
                    Categorias
                  </Button>
                </Group>
              </Stack>
            </Card>

            {/* Status filter + grid */}
            <Stack gap="sm">
              <Group gap={6}>
                {STATUS_FILTERS.map((f) => (
                  <Chip
                    key={f.value}
                    checked={selectedStatus === f.value}
                    onChange={() => setSelectedStatus(selectedStatus === f.value ? null : f.value)}
                    color={f.color}
                    variant="filled"
                    size="sm"
                  >
                    {f.label}
                  </Chip>
                ))}
                {selectedStatus && (
                  <ActionIcon
                    variant="subtle"
                    color="gray"
                    size="sm"
                    onClick={() => setSelectedStatus(null)}
                    aria-label="Limpar filtro"
                  >
                    <X size={14} />
                  </ActionIcon>
                )}
              </Group>

              {displayProducts.length > 0 ? (
                <SimpleGrid cols={{ base: 2, sm: 3, lg: 4 }} spacing="md">
                  {displayProducts.map((p) => (
                    <ProductCard key={p.id_produto} product={p} />
                  ))}
                </SimpleGrid>
              ) : (
                <Center py="xl">
                  <Text c="dimmed" size="sm">Nenhum produto encontrado para este período.</Text>
                </Center>
              )}
            </Stack>
          </Stack>
        )}
      </AppShell.Main>

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
    </AppShell>
  )
}
