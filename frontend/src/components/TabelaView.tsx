'use client'

import { useMemo, useState } from 'react'
import {
  useReactTable,
  getCoreRowModel,
  getSortedRowModel,
  getFilteredRowModel,
  getPaginationRowModel,
  flexRender,
  SortingState,
  ColumnDef,
  ColumnFiltersState,
} from '@tanstack/react-table'
import { ChevronUp, ChevronDown, ChevronsUpDown, Search, FilterX } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Badge } from './ui/badge'
import { Button } from './ui/button'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from './ui/table'
import { useSazonalidadeComPreco, type ProdutoComPreco } from '../hooks/useSazonalidadeComPreco'

const STATUS_COLORS: Record<string, { bg: string; text: string; border: string }> = {
  VERDE: {
    bg: 'bg-sazonal-verde-100 dark:bg-sazonal-verde-dark/30',
    text: 'text-sazonal-verde-700 dark:text-sazonal-verde-400',
    border: 'border-sazonal-verde-600',
  },
  AMARELO: {
    bg: 'bg-sazonal-amarelo-100 dark:bg-sazonal-amarelo-dark/30',
    text: 'text-sazonal-amarelo-700 dark:text-sazonal-amarelo-400',
    border: 'border-sazonal-amarelo-600',
  },
  VERMELHO: {
    bg: 'bg-sazonal-vermelho-100 dark:bg-sazonal-vermelho-dark/30',
    text: 'text-sazonal-vermelho-700 dark:text-sazonal-vermelho-400',
    border: 'border-sazonal-vermelho-600',
  },
  CINZA: {
    bg: 'bg-gray-100 dark:bg-gray-800',
    text: 'text-gray-500 dark:text-gray-400',
    border: 'border-gray-400',
  },
}

const TENDENCIA_ICONS: Record<string, React.ReactNode> = {
  QUEDA: <ChevronDown className="h-4 w-4 text-green-600 dark:text-green-400" />,
  ALTA: <ChevronUp className="h-4 w-4 text-red-600 dark:text-red-400" />,
  ESTAVEL: <ChevronsUpDown className="h-4 w-4 text-gray-500 dark:text-gray-400" />,
}

interface TabelaViewProps {
  uf: string
  categoria?: string | null
  ano?: number | null
  mes?: number | null
  onSelectProduto?: (produto: ProdutoComPreco) => void
  selectedProduto?: { nome_produto: string; categoria: string | null; uf: string } | null
}

export function TabelaView({
  uf,
  categoria,
  ano,
  mes,
  onSelectProduto,
  selectedProduto,
}: TabelaViewProps) {
  const query = useSazonalidadeComPreco(uf, categoria, ano, mes, 1, 2000)
  const [sorting, setSorting] = useState<SortingState>([{ id: 'status_cor', desc: false }])
  const [globalFilter, setGlobalFilter] = useState('')
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([])

  const products = query.data?.data ?? []
  const isLoading = query.isLoading
  const isError = query.isError
  const total = query.data?.total ?? 0

  // Build columns inline to avoid type issues
  const columns = useMemo<ColumnDef<ProdutoComPreco>[]>(
    () => [
      {
        id: 'nome_produto',
        header: 'Produto',
        accessorFn: (row: ProdutoComPreco) => row.nome_produto,
        cell: (info) => <div className="font-medium">{info.getValue() as string}</div>,
        size: 200,
      },
      {
        id: 'categoria',
        header: 'Categoria',
        accessorFn: (row: ProdutoComPreco) => row.categoria,
        cell: (info) => (info.getValue() as string) ?? '—',
        size: 120,
      },
      {
        id: 'uf',
        header: 'UF',
        accessorFn: (row: ProdutoComPreco) => row.uf,
        cell: (info) => <span className="font-mono text-sm">{info.getValue() as string}</span>,
        size: 60,
      },
      {
        id: 'ano',
        header: 'Ano',
        accessorFn: (row: ProdutoComPreco) => row.ano,
        cell: (info) => info.getValue() as number,
        size: 60,
      },
      {
        id: 'mes',
        header: 'Mês',
        accessorFn: (row: ProdutoComPreco) => row.mes,
        cell: (info) => String(info.getValue() as number).padStart(2, '0'),
        size: 60,
      },
      {
        id: 'preco_referencia',
        header: 'Ref. (R$)',
        accessorFn: (row: ProdutoComPreco) => row.preco_referencia,
        cell: (info) => {
          const val = info.getValue() as number | null
          return val != null ? `R$ ${val.toFixed(2)}` : '—'
        },
        size: 100,
      },
      {
        id: 'preco_atual',
        header: 'Atual (R$)',
        accessorFn: (row: ProdutoComPreco) => row.preco_atual,
        cell: (info) => {
          const val = info.getValue() as number | null
          return val != null ? `R$ ${val.toFixed(2)}` : '—'
        },
        size: 100,
      },
      {
        id: 'preco_mes_anterior',
        header: 'Mês Ant. (R$)',
        accessorFn: (row: ProdutoComPreco) => row.preco_mes_anterior,
        cell: (info) => {
          const val = info.getValue() as number | null
          return val != null ? `R$ ${val.toFixed(2)}` : '—'
        },
        size: 100,
      },
      {
        id: 'variacao_pct',
        header: 'Var. %',
        accessorFn: (row: ProdutoComPreco) => row.variacao_pct,
        cell: (info) => {
          const val = info.getValue() as number | null
          if (val === null || val === undefined) return '—'
          const isPositive = val > 0
          return (
            <span
              className={cn(
                'font-mono font-medium',
                isPositive ? 'text-red-600' : 'text-green-600',
              )}
            >
              {isPositive ? '+' : ''}
              {val.toFixed(1)}%
            </span>
          )
        },
        size: 80,
      },
      {
        id: 'status_cor',
        header: 'Status',
        accessorFn: (row: ProdutoComPreco) => row.status_cor,
        cell: (info) => {
          const raw = info.getValue()
          const status = (raw ?? '') as string
          const colors =
            STATUS_COLORS[status] ?? (status === '' ? STATUS_COLORS.CINZA : STATUS_COLORS.VERDE)
          return (
            <Badge
              variant="secondary"
              className={cn(colors.bg, colors.text, colors.border, 'capitalize')}
            >
              {status ? status.toLowerCase() : 'sem dados'}
            </Badge>
          )
        },
        size: 100,
      },
      {
        id: 'tendencia_futura',
        header: 'Tendência',
        accessorFn: (row: ProdutoComPreco) => row.tendencia_futura,
        cell: (info) => {
          const tendencia = info.getValue() as 'QUEDA' | 'ALTA' | 'ESTAVEL' | null
          return (
            <div className="flex items-center justify-center">
              {tendencia ? TENDENCIA_ICONS[tendencia] : '—'}
            </div>
          )
        },
        size: 80,
      },
      {
        id: 'is_forecast',
        header: 'Projetado',
        accessorFn: (row: ProdutoComPreco) => row.is_forecast,
        cell: (info) =>
          (info.getValue() as boolean) ? (
            <Badge variant="outline" className="text-xs">
              Sim
            </Badge>
          ) : (
            '—'
          ),
        size: 80,
      },
      {
        id: 'confianca_baseline',
        header: 'Confiança %',
        accessorFn: (row: ProdutoComPreco) => row.confianca_baseline,
        cell: (info) => {
          const val = info.getValue() as number | null
          return val != null ? `${val.toFixed(0)}%` : '—'
        },
        size: 80,
      },
    ],
    [],
  )

  const table = useReactTable({
    data: products,
    columns,
    state: { sorting, globalFilter, columnFilters },
    onSortingChange: setSorting,
    onGlobalFilterChange: setGlobalFilter,
    onColumnFiltersChange: setColumnFilters,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getPaginationRowModel: getPaginationRowModel(),
    manualPagination: true,
    pageCount: 1,
  })

  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(5)].map((_, i) => (
          <div key={i} className="h-10 animate-pulse rounded bg-gray-100 dark:bg-gray-800" />
        ))}
      </div>
    )
  }

  if (isError) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-center dark:border-red-800 dark:bg-red-900/20">
        <p className="text-red-700 dark:text-red-400">Erro ao carregar dados da tabela.</p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {/* Toolbar */}
      <div className="flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center">
        <div className="flex gap-2">
          <div className="relative">
            <Search className="absolute left-2 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
            <input
              type="search"
              placeholder="Filtrar produtos..."
              value={globalFilter}
              onChange={(e) => setGlobalFilter(e.target.value)}
              className="h-9 w-64 rounded-md border border-gray-300 bg-white pl-9 pr-3 text-sm outline-none focus:ring-2 focus:ring-sazonal-verde-600 dark:border-gray-600 dark:bg-gray-800"
            />
          </div>
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              setGlobalFilter('')
              setColumnFilters([])
            }}
            disabled={!globalFilter && columnFilters.length === 0}
          >
            <FilterX className="mr-1 h-4 w-4" />
            Limpar
          </Button>
        </div>
        <Badge variant="secondary" className="text-xs">
          {total} produto{total !== 1 ? 's' : ''}
        </Badge>
      </div>

      {/* Table */}
      <div className="overflow-hidden rounded-xl border border-gray-200 dark:border-gray-700">
        <Table>
          <TableHeader>
            {table.getHeaderGroups().map((headerGroup) => (
              <TableRow key={headerGroup.id}>
                {headerGroup.headers.map((header) => (
                  <TableHead key={header.id} className="cursor-pointer select-none">
                    {header.isPlaceholder ? null : (
                      <div
                        className="flex items-center gap-1"
                        onClick={header.column.getToggleSortingHandler()}
                      >
                        {flexRender(header.column.columnDef.header, header.getContext())}
                        {{
                          asc: <ChevronUp className="h-4 w-4" />,
                          desc: <ChevronDown className="h-4 w-4" />,
                        }[header.column.getIsSorted() as string] ?? (
                          <ChevronsUpDown className="h-4 w-4 text-gray-400" />
                        )}
                      </div>
                    )}
                  </TableHead>
                ))}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody>
            {table.getRowModel().rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={columns.length} className="py-8 text-center text-gray-500">
                  Nenhum produto encontrado.
                </TableCell>
              </TableRow>
            ) : (
              table.getRowModel().rows.map((row) => (
                <TableRow
                  key={row.id}
                  className={cn(
                    'cursor-pointer transition-colors',
                    selectedProduto?.nome_produto === row.original.nome_produto &&
                      selectedProduto?.categoria === row.original.categoria &&
                      selectedProduto?.uf === row.original.uf &&
                      'bg-sazonal-verde-50 dark:bg-sazonal-verde-dark/20',
                  )}
                  onClick={() => onSelectProduto?.(row.original)}
                >
                  {row.getVisibleCells().map((cell) => (
                    <TableCell key={cell.id}>
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </TableCell>
                  ))}
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>
    </div>
  )
}
