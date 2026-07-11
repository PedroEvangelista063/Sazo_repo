import { Badge, Card, Group, Stack, Text, Tooltip } from '@mantine/core'
import { CheckCircle2, MinusCircle, XCircle } from 'lucide-react'
import type { ProdutoVarejo } from '../types/domain'

const PRODUTO_EMOJI: Record<string, string> = {
  ARROZ: '🍚', BANANA: '🍌', BATATA: '🥔', CAFE: '☕',
  CEBOLA: '🧅', CENOURA: '🥕', FEIJAO: '🫘', LARANJA: '🍊',
  LEITE: '🥛', MACA: '🍎', MANDIOCA: '🌿', MILHO: '🌽',
  OVO: '🥚', REPOLHO: '🥬', SOJA: '🫘', TOMATE: '🍅',
  UVA: '🍇', ALFACE: '🥬', BETERRABA: '🥗', PIMENTAO: '🫑',
  FRANGO: '🍗', CARNE: '🥩', QUEIJO: '🧀', IOGURTE: '🥛',
  OLEO: '🫒', ACUCAR: '🍚', FARINHA: '🌾', MACARRAO: '🍝',
}

const STATUS_CONFIG: Record<string, { label: string; color: string; border: string }> = {
  VERDE: { label: 'Melhor Época!', color: 'green', border: 'var(--mantine-color-green-5)' },
  AMARELO: { label: 'Preço Normal', color: 'yellow', border: 'var(--mantine-color-yellow-5)' },
  VERMELHO: { label: 'Péssima Época', color: 'red', border: 'var(--mantine-color-red-5)' },
}

function getEmoji(name: string): string {
  const key = name.toUpperCase().replace(/[^A-Z ]/g, '').trim().split(/\s+/)[0] ?? ''
  return PRODUTO_EMOJI[key] ?? '🛒'
}

interface ProductCardProps {
  product: ProdutoVarejo
}

export function ProductCard({ product }: ProductCardProps) {
  const config = STATUS_CONFIG[product.status_cor] ?? { label: 'Dados Insuficientes', color: 'gray', border: 'var(--mantine-color-gray-5)' }
  const emoji = getEmoji(product.nome_produto)
  const Icon = product.status_cor === 'VERDE' ? CheckCircle2
    : product.status_cor === 'AMARELO' ? MinusCircle
    : XCircle

  return (
    <Card withBorder padding="md" radius="md" miw={140} style={{ borderLeft: `4px solid ${config.border}` }}>
      <Stack align="center" gap={4}>
        <Text fz={28} role="img" aria-label={product.nome_produto}>{emoji}</Text>
        <Text fz="sm" fw={700} ta="center" lh={1.3}>{product.nome_produto}</Text>
        <Group gap={4} justify="center" wrap="wrap">
          <Group gap={4}>
            <Icon size={14} />
            <Text fz="xs" c={config.color}>{config.label}</Text>
          </Group>
          {product.is_forecast && (
            <Tooltip
              label={`Dado estimado com base no histórico de 2024–2025. Confiança: ${product.confianca_baseline ?? '?'}%`}
              withArrow
              openDelay={300}
            >
              <Badge variant="outline" color="gray" size="xs">📊 Estimativa</Badge>
            </Tooltip>
          )}
        </Group>
        {product.usou_fallback_12m && (
          <Text fz={10} ta="center" c="dimmed">* Média 12 meses</Text>
        )}
      </Stack>
    </Card>
  )
}
