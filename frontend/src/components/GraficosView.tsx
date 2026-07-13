'use client'

import { useMemo } from 'react'
import {
  LineChart,
  Line,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
  Cell,
} from 'recharts'
import { TrendingUp } from 'lucide-react'
import { Badge } from './ui/badge'
import { Card, CardContent, CardHeader, CardTitle } from './ui/card'
import { useSazonalidadeComPreco, type ProdutoComPreco } from '../hooks/useSazonalidadeComPreco'

const MESES = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']

const STATUS_COLORS: Record<string, string> = {
  VERDE: '#16a34a',
  AMARELO: '#ca8a04',
  VERMELHO: '#dc2626',
}

interface SelectedProduto {
  nome_produto: string
  categoria: string | null
  uf: string
}

interface GraficosViewProps {
  uf: string
  categoria?: string | null
  ano?: number | null
  mes?: number | null
  selectedProduto?: SelectedProduto | null
}

interface ChartDataPoint {
  label: string
  preco_atual: number | null
  preco_referencia: number | null
  preco_mes_anterior: number | null
  variacao_pct: number | null
  status_cor: string
  ano: number
  mes: number
}

interface ComparisonDataPoint {
  label: string
  preco_atual: number
  status_cor: string
}

export function GraficosView({ uf, categoria, ano, mes, selectedProduto }: GraficosViewProps) {
  const query = useSazonalidadeComPreco(uf, categoria, ano, mes, 1, 2000)
  const products = query.data?.data ?? []
  const isLoading = query.isLoading
  const isError = query.isError

  const chartData = useMemo<ChartDataPoint[]>(() => {
    if (!selectedProduto) return []
    const filtered = products.filter(
      (p: ProdutoComPreco) => p.nome_produto === selectedProduto.nome_produto && p.categoria === selectedProduto.categoria
    )
    return filtered
      .sort((a: ProdutoComPreco, b: ProdutoComPreco) => a.ano - b.ano || a.mes - b.mes)
      .map((p: ProdutoComPreco) => ({
        label: `${MESES[p.mes - 1]}/${String(p.ano).slice(2)}`,
        preco_atual: p.preco_atual,
        preco_referencia: p.preco_referencia,
        preco_mes_anterior: p.preco_mes_anterior,
        variacao_pct: p.variacao_pct,
        status_cor: p.status_cor,
        ano: p.ano,
        mes: p.mes,
      }))
  }, [products, selectedProduto])

  const comparisonData = useMemo<ComparisonDataPoint[]>(() => {
    if (!selectedProduto) return []
    return products
      .filter(
        (p: ProdutoComPreco) =>
          p.nome_produto === selectedProduto.nome_produto &&
          p.categoria === selectedProduto.categoria &&
          p.preco_atual != null
      )
      .sort((a: ProdutoComPreco, b: ProdutoComPreco) => (a.preco_atual ?? 0) - (b.preco_atual ?? 0))
      .slice(0, 10)
      .map((p: ProdutoComPreco) => ({
        label: `${p.uf}${p.municipio ? ` - ${p.municipio}` : ''}`,
        preco_atual: p.preco_atual!,
        status_cor: p.status_cor,
      }))
  }, [products, selectedProduto])

  if (isLoading) {
    return (
      <div className="space-y-6">
        {[1, 2].map((i) => (
          <Card key={i} className="animate-pulse">
            <CardHeader>
              <CardTitle className="h-4 w-1/4 bg-gray-200 dark:bg-gray-700 rounded" />
            </CardHeader>
            <CardContent>
              <div className="h-64 bg-gray-100 dark:bg-gray-800 rounded" />
            </CardContent>
          </Card>
        ))}
      </div>
    )
  }

  if (isError) {
    return (
      <Card className="border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-900/20">
        <CardContent className="p-6 text-center text-red-700 dark:text-red-400">
          Erro ao carregar dados dos gráficos.
        </CardContent>
      </Card>
    )
  }

  if (!selectedProduto) {
    return (
      <Card>
        <CardContent className="p-8 text-center">
          <TrendingUp className="w-12 h-12 mx-auto text-gray-300 dark:text-gray-600 mb-3" />
          <h3 className="text-lg font-medium text-gray-900 dark:text-gray-100 mb-1">
            Selecione um produto na tabela
          </h3>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Clique em uma linha da tabela para ver a evolução de preços e comparação entre UFs.
          </p>
        </CardContent>
      </Card>
    )
  }

  const CustomTooltip = ({ active, payload, label }: { active?: boolean; payload?: Array<{ value: number; name: string; color: string }>; label?: string }) => {
    if (!active || !payload) return null
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-lg p-3">
        <p className="font-medium text-gray-900 dark:text-gray-100">{label}</p>
        {payload.map((entry, index) => (
          <p key={index} className="text-sm" style={{ color: entry.color }}>
            {entry.name}: {entry.value !== null && entry.value !== undefined ? `R$ ${entry.value.toFixed(2)}` : '—'}
          </p>
        ))}
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* Header do produto selecionado */}
      <Card>
        <CardContent className="p-4">
          <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
            <div className="flex items-center gap-3">
              <div className="text-4xl">🛒</div>
              <div>
                <h3 className="text-lg font-bold text-gray-900 dark:text-gray-100">{selectedProduto.nome_produto}</h3>
                <p className="text-sm text-gray-500 dark:text-gray-400">
                  {selectedProduto.categoria} • {selectedProduto.uf}
                </p>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <Badge variant="secondary" className="capitalize">
                {products.find((p: ProdutoComPreco) => p.nome_produto === selectedProduto.nome_produto)?.status_cor?.toLowerCase()}
              </Badge>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Gráfico de Linha - Evolução de Preços */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <TrendingUp className="w-5 h-5 text-sazonal-verde-600" />
            Evolução de Preços
          </CardTitle>
        </CardHeader>
        <CardContent>
          <div className="h-80">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={chartData} margin={{ top: 5, right: 30, left: 20, bottom: 5 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#e5e7eb" vertical={false} />
                <XAxis
                  dataKey="label"
                  tick={{ fontSize: 11, fill: '#6b7280' }}
                  axisLine={{ stroke: '#e5e7eb' }}
                  tickLine={false}
                />
                <YAxis
                  tick={{ fontSize: 11, fill: '#6b7280' }}
                  axisLine={false}
                  tickLine={false}
                  tickFormatter={(value) => `R$ ${value.toFixed(2)}`}
                />
                <Tooltip content={<CustomTooltip />} />
                <Legend />
                <Line
                  type="monotone"
                  dataKey="preco_atual"
                  name="Preço Atual"
                  stroke="#2563eb"
                  strokeWidth={2}
                  dot={{ r: 4, fill: '#2563eb' }}
                  activeDot={{ r: 6, fill: '#2563eb' }}
                />
                {chartData.some((d) => d.preco_referencia != null) && (
                  <Line
                    type="monotone"
                    dataKey="preco_referencia"
                    name="Preço Referência"
                    stroke="#16a34a"
                    strokeWidth={2}
                    strokeDasharray="5 5"
                    dot={{ r: 3, fill: '#16a34a' }}
                    activeDot={{ r: 5, fill: '#16a34a' }}
                  />
                )}
                {chartData.some((d) => d.preco_mes_anterior != null) && (
                  <Line
                    type="monotone"
                    dataKey="preco_mes_anterior"
                    name="Mês Anterior"
                    stroke="#f59e0b"
                    strokeWidth={1.5}
                    strokeDasharray="2 2"
                    dot={{ r: 3, fill: '#f59e0b' }}
                    activeDot={{ r: 5, fill: '#f59e0b' }}
                  />
                )}
              </LineChart>
            </ResponsiveContainer>
          </div>
          <div className="mt-3 flex flex-wrap gap-2 text-xs text-gray-500 dark:text-gray-400">
            <span className="flex items-center gap-1">
              <span className="w-3 h-3 rounded-full" style={{ backgroundColor: '#2563eb' }} />
              Atual
            </span>
            {chartData.some((d) => d.preco_referencia != null) && (
              <span className="flex items-center gap-1">
                <span className="w-3 h-3 rounded" style={{ background: 'repeating-linear-gradient(90deg, #16a34a, #16a34a 4px, transparent 4px, transparent 8px)' }} />
                Referência
              </span>
            )}
            {chartData.some((d) => d.preco_mes_anterior != null) && (
              <span className="flex items-center gap-1">
                <span className="w-3 h-3 rounded" style={{ background: 'repeating-linear-gradient(90deg, #f59e0b, #f59e0b 2px, transparent 2px, transparent 4px)' }} />
                Mês Anterior
              </span>
            )}
          </div>
        </CardContent>
      </Card>

      {/* Gráfico de Barras - Comparação entre UFs/Municípios */}
      {comparisonData.length > 1 && (
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <TrendingUp className="w-5 h-5 text-sazonal-amarelo-600" />
              Comparação de Preços por Localidade
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="h-80">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={comparisonData} margin={{ top: 5, right: 30, left: 20, bottom: 60 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e5e7eb" vertical={false} />
                  <XAxis
                    dataKey="label"
                    tick={{ fontSize: 10, fill: '#6b7280' }}
                    axisLine={{ stroke: '#e5e7eb' }}
                    tickLine={false}
                    tickMargin={8}
                    angle={-45}
                    textAnchor="end"
                    height={60}
                  />
                  <YAxis
                    tick={{ fontSize: 11, fill: '#6b7280' }}
                    axisLine={false}
                    tickLine={false}
                    tickFormatter={(value) => `R$ ${value.toFixed(2)}`}
                  />
                  <Tooltip content={<CustomTooltip />} />
                  <Bar
                    dataKey="preco_atual"
                    name="Preço Atual"
                    radius={[4, 4, 0, 0]}
                  >
                    {comparisonData.map((entry, index) => (
                      <Cell key={`cell-${index}`} fill={STATUS_COLORS[entry.status_cor] || '#6b7280'} />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </div>
            <div className="mt-3 flex flex-wrap gap-2 text-xs text-gray-500 dark:text-gray-400">
              {['VERDE', 'AMARELO', 'VERMELHO'].map((status) => (
                <span key={status} className="flex items-center gap-1">
                  <span className="w-3 h-3 rounded" style={{ backgroundColor: STATUS_COLORS[status] }} />
                  {status.toLowerCase()}
                </span>
              ))}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Resumo estatístico */}
      {chartData.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Resumo Estatístico</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
              <StatCard
                label="Preço Médio"
                value={chartData.filter((d) => d.preco_atual != null).reduce((a, b) => a + (b.preco_atual || 0), 0) / chartData.filter((d) => d.preco_atual != null).length || 0}
                format="currency"
              />
              <StatCard
                label="Menor Preço"
                value={Math.min(...chartData.filter((d) => d.preco_atual != null).map((d) => d.preco_atual!)) || 0}
                format="currency"
              />
              <StatCard
                label="Maior Preço"
                value={Math.max(...chartData.filter((d) => d.preco_atual != null).map((d) => d.preco_atual!)) || 0}
                format="currency"
              />
              <StatCard
                label="Variação Média"
                value={chartData.filter((d) => d.variacao_pct != null).reduce((a, b) => a + (b.variacao_pct || 0), 0) / chartData.filter((d) => d.variacao_pct != null).length || 0}
                format="percent"
              />
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  )
}

interface StatCardProps {
  label: string
  value: number
  format: 'currency' | 'percent'
}

function StatCard({ label, value, format }: StatCardProps) {
  return (
    <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4 text-center">
      <p className="text-xs text-gray-500 dark:text-gray-400 mb-1">{label}</p>
      <p className="text-xl font-bold text-gray-900 dark:text-gray-100">
        {format === 'currency' ? `R$ ${value.toFixed(2)}` : `${value >= 0 ? '+' : ''}${value.toFixed(1)}%`}
      </p>
    </div>
  )
}