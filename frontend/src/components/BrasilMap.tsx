import { useState } from 'react'
import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'
import type { FlowItem } from '@/types/domain'

interface BrasilMapProps {
  selectedRegion: string | null
  onRegionClick: (regionId: string) => void
  fluxos?: FlowItem[]
  className?: string
}

interface UFDot {
  uf: string
  nome: string
  regiao: string
  cx: number
  cy: number
}

const REGIOES_META: Record<string, { id: string; label: string; cor: string; corClara: string; corEscura: string }> = {
  norte: {
    id: 'norte',
    label: 'Norte',
    cor: '#16a34a',
    corClara: '#dcfce7',
    corEscura: '#14532d',
  },
  nordeste: {
    id: 'nordeste',
    label: 'Nordeste',
    cor: '#0284c7',
    corClara: '#e0f2fe',
    corEscura: '#0c4a6e',
  },
  'centro-oeste': {
    id: 'centro-oeste',
    label: 'Centro-Oeste',
    cor: '#d97706',
    corClara: '#fef3c7',
    corEscura: '#78350f',
  },
  sudeste: {
    id: 'sudeste',
    label: 'Sudeste',
    cor: '#e11d48',
    corClara: '#ffe4e6',
    corEscura: '#881337',
  },
  sul: {
    id: 'sul',
    label: 'Sul',
    cor: '#7c3aed',
    corClara: '#ede9fe',
    corEscura: '#4c1d95',
  },
}

const UFS: UFDot[] = [
  // Norte
  { uf: 'AC', nome: 'Acre', regiao: 'norte', cx: 50, cy: 130 },
  { uf: 'AP', nome: 'Amapá', regiao: 'norte', cx: 300, cy: 30 },
  { uf: 'AM', nome: 'Amazonas', regiao: 'norte', cx: 155, cy: 75 },
  { uf: 'PA', nome: 'Pará', regiao: 'norte', cx: 265, cy: 60 },
  { uf: 'RO', nome: 'Rondônia', regiao: 'norte', cx: 90, cy: 150 },
  { uf: 'RR', nome: 'Roraima', regiao: 'norte', cx: 190, cy: 20 },
  { uf: 'TO', nome: 'Tocantins', regiao: 'norte', cx: 235, cy: 135 },

  // Nordeste
  { uf: 'AL', nome: 'Alagoas', regiao: 'nordeste', cx: 385, cy: 175 },
  { uf: 'BA', nome: 'Bahia', regiao: 'nordeste', cx: 370, cy: 200 },
  { uf: 'CE', nome: 'Ceará', regiao: 'nordeste', cx: 380, cy: 105 },
  { uf: 'MA', nome: 'Maranhão', regiao: 'nordeste', cx: 320, cy: 85 },
  { uf: 'PB', nome: 'Paraíba', regiao: 'nordeste', cx: 405, cy: 145 },
  { uf: 'PE', nome: 'Pernambuco', regiao: 'nordeste', cx: 395, cy: 160 },
  { uf: 'PI', nome: 'Piauí', regiao: 'nordeste', cx: 340, cy: 125 },
  { uf: 'RN', nome: 'Rio Grande do Norte', regiao: 'nordeste', cx: 415, cy: 125 },
  { uf: 'SE', nome: 'Sergipe', regiao: 'nordeste', cx: 385, cy: 190 },

  // Centro-Oeste
  { uf: 'DF', nome: 'Distrito Federal', regiao: 'centro-oeste', cx: 230, cy: 208 },
  { uf: 'GO', nome: 'Goiás', regiao: 'centro-oeste', cx: 220, cy: 195 },
  { uf: 'MS', nome: 'Mato Grosso do Sul', regiao: 'centro-oeste', cx: 175, cy: 275 },
  { uf: 'MT', nome: 'Mato Grosso', regiao: 'centro-oeste', cx: 150, cy: 190 },

  // Sudeste
  { uf: 'ES', nome: 'Espírito Santo', regiao: 'sudeste', cx: 365, cy: 265 },
  { uf: 'MG', nome: 'Minas Gerais', regiao: 'sudeste', cx: 315, cy: 240 },
  { uf: 'RJ', nome: 'Rio de Janeiro', regiao: 'sudeste', cx: 345, cy: 288 },
  { uf: 'SP', nome: 'São Paulo', regiao: 'sudeste', cx: 275, cy: 308 },

  // Sul
  { uf: 'PR', nome: 'Paraná', regiao: 'sul', cx: 255, cy: 340 },
  { uf: 'RS', nome: 'Rio Grande do Sul', regiao: 'sul', cx: 230, cy: 395 },
  { uf: 'SC', nome: 'Santa Catarina', regiao: 'sul', cx: 265, cy: 368 },
]

const REGIOES = Object.values(REGIOES_META)

function formatLabel(regiaoId: string): string {
  if (regiaoId === 'centro-oeste') return 'Centro-Oeste'
  return regiaoId.charAt(0).toUpperCase() + regiaoId.slice(1)
}

export function BrasilMap({ selectedRegion, onRegionClick, fluxos, className }: BrasilMapProps) {
  const [showFluxos, setShowFluxos] = useState(false)
  const hasFluxos = fluxos && fluxos.length > 0

  const ufMap = new Map(UFS.map((u) => [u.uf, u]))

  const arcs = showFluxos && fluxos
    ? fluxos
        .map((f) => {
          const from = ufMap.get(f.origem_uf)
          const to = ufMap.get(f.destino_uf)
          if (!from || !to || from.uf === to.uf) return null
          return { from, to, flow: f }
        })
        .filter(Boolean)
    : []

  return (
    <div className={cn('relative w-full max-w-[420px] mx-auto', className)}>
      <svg
        viewBox="0 0 500 450"
        className="w-full h-auto"
        xmlns="http://www.w3.org/2000/svg"
        role="img"
        aria-label="Mapa do Brasil por estados"
      >
        <defs>
          {REGIOES.map((reg) => (
            <radialGradient
              key={`glow-${reg.id}`}
              id={`glow-${reg.id}`}
              cx="50%"
              cy="50%"
              r="50%"
            >
              <stop offset="0%" stopColor={reg.cor} stopOpacity="0.35" />
              <stop offset="100%" stopColor={reg.cor} stopOpacity="0" />
            </radialGradient>
          ))}
        </defs>

        {/* Legendas das regiões */}
        {REGIOES.map((reg) => {
          const ufs = UFS.filter((u) => u.regiao === reg.id)
          const midX = ufs.reduce((s, u) => s + u.cx, 0) / ufs.length
          const midY = ufs.reduce((s, u) => s + u.cy, 0) / ufs.length
          const isSelected = selectedRegion === reg.id
          return (
            <motion.g
              key={reg.id}
              className="cursor-pointer"
              onClick={() => onRegionClick(reg.id)}
              initial={false}
              animate={{
                opacity: selectedRegion && !isSelected ? 0.4 : 1,
              }}
              transition={{ duration: 0.3 }}
            >
              {/* Glow de fundo para região selecionada */}
              {isSelected && (
                <circle
                  cx={midX}
                  cy={midY}
                  r={110}
                  fill={`url(#glow-${reg.id})`}
                  className="pointer-events-none"
                />
              )}
            </motion.g>
          )
        })}

        {/* Linhas conectando dots de cada região */}
        {REGIOES.map((reg) => {
          const ufs = UFS.filter((u) => u.regiao === reg.id)
          const isSelected = selectedRegion === reg.id || selectedRegion === null
          if (ufs.length < 2) return null
          // Convex hull aproximado — conecta os dots da região
          return (
            <motion.path
              key={`line-${reg.id}`}
              d={buildRegionPath(ufs)}
              fill="none"
              stroke={reg.cor}
              strokeWidth={isSelected ? 1 : 0.5}
              strokeOpacity={isSelected ? 0.3 : 0.1}
              strokeDasharray="4 3"
              className="pointer-events-none"
              initial={false}
              animate={{ strokeOpacity: isSelected ? 0.3 : 0.1 }}
              transition={{ duration: 0.3 }}
            />
          )
        })}

        {/* Arcos de fluxo de abastecimento */}
        {arcs.length > 0 && (
          <g className="pointer-events-none">
            {arcs.map((arc, idx) => {
              if (!arc) return null
              const { from, to, flow } = arc
              const mx = (from.cx + to.cx) / 2
              const my = (from.cy + to.cy) / 2 - 30
              const d = `M ${from.cx} ${from.cy} Q ${mx} ${my} ${to.cx} ${to.cy}`
              return (
                <g key={`arc-${flow.id}-${idx}`}>
                  {/* Sombra do arco */}
                  <path
                    d={d}
                    fill="none"
                    stroke="rgba(0,0,0,0.15)"
                    strokeWidth={2.5}
                    transform="translate(0, 2)"
                  />
                  {/* Arco principal animado */}
                  <motion.path
                    d={d}
                    fill="none"
                    stroke={flow.cor_indicadora}
                    strokeWidth={2}
                    strokeOpacity={0.7}
                    strokeLinecap="round"
                    initial={{ pathLength: 0 }}
                    animate={{ pathLength: 1 }}
                    transition={{ duration: 1, delay: idx * 0.1, ease: 'easeInOut' }}
                  />
                </g>
              )
            })}
          </g>
        )}

        {/* Dots individuais por UF */}
        {UFS.map((uf) => {
          const reg = REGIOES_META[uf.regiao]
          const isSelected = selectedRegion === uf.regiao
          const isDimmed = selectedRegion !== null && !isSelected
          const dotRadius = isSelected ? 13 : 9
          const labelRadius = isSelected ? 20 : 14

          return (
            <motion.g
              key={uf.uf}
              className="cursor-pointer"
              onClick={() => onRegionClick(uf.regiao)}
              initial={false}
              animate={{
                opacity: isDimmed ? 0.35 : 1,
              }}
              transition={{ duration: 0.3 }}
            >
              {/* Sombra */}
              <circle
                cx={uf.cx + 1}
                cy={uf.cy + 1.5}
                r={dotRadius}
                fill="rgba(0,0,0,0.15)"
                className="pointer-events-none"
              />

              {/* Círculo principal */}
              <motion.circle
                cx={uf.cx}
                cy={uf.cy}
                r={dotRadius}
                fill={reg.cor}
                fillOpacity={isSelected ? 1 : 0.75}
                stroke={isSelected ? '#fff' : 'none'}
                strokeWidth={isSelected ? 2 : 0}
                animate={{
                  r: isSelected ? 13 : 9,
                  fillOpacity: isSelected ? 1 : 0.75,
                }}
                transition={{ duration: 0.2 }}
                whileHover={{ r: 14 }}
              />

              {/* Label UF */}
              <motion.text
                x={uf.cx}
                y={uf.cy}
                textAnchor="middle"
                dominantBaseline="central"
                fill="#fff"
                fontSize={isSelected ? 7 : 6}
                fontWeight={700}
                className="pointer-events-none select-none"
                animate={{ fontSize: isSelected ? 7 : 6 }}
                transition={{ duration: 0.2 }}
              >
                {uf.uf}
              </motion.text>

              {/* Nome do estado — aparece só no hover/selected */}
              {(isSelected || selectedRegion === null) && (
                <motion.text
                  x={uf.cx}
                  y={uf.cy + labelRadius + 9}
                  textAnchor="middle"
                  dominantBaseline="central"
                  fill={reg.cor}
                  className="pointer-events-none select-none"
                  fontSize={8}
                  fontWeight={500}
                  initial={{ opacity: 0, y: uf.cy + labelRadius + 5 }}
                  animate={{ opacity: 1, y: uf.cy + labelRadius + 9 }}
                  transition={{ duration: 0.15 }}
                >
                  {uf.uf === 'DF' ? 'DF' : uf.nome.substring(0, 6)}
                </motion.text>
              )}
            </motion.g>
          )
        })}
      </svg>

      {/* Controles do mapa */}
      <div className="flex flex-wrap items-center justify-center gap-2 mt-4">
        {hasFluxos && (
          <motion.button
            onClick={() => setShowFluxos((v) => !v)}
            className={cn(
              'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-medium border transition-colors',
              showFluxos
                ? 'bg-indigo-600 border-indigo-600 text-white'
                : 'border-indigo-400 text-indigo-500',
            )}
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
          >
            <svg className="w-3 h-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
              <path d="M5 12h14M12 5l7 7-7 7" />
            </svg>
            {showFluxos ? 'Ocultar Fluxos' : `Fluxos (${fluxos!.length})`}
          </motion.button>
        )}
      </div>

      {/* Legenda interativa abaixo do mapa */}
      <div className="flex flex-wrap justify-center gap-2 mt-2">
        {REGIOES.map((reg) => {
          const isActive = selectedRegion === reg.id
          return (
            <motion.button
              key={reg.id}
              onClick={() => onRegionClick(reg.id)}
              className={cn(
                'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-medium',
                'border transition-colors',
              )}
              style={{
                backgroundColor: isActive ? reg.cor : 'transparent',
                borderColor: reg.cor,
                color: isActive ? '#fff' : reg.cor,
              }}
              whileHover={{ scale: 1.05 }}
              whileTap={{ scale: 0.95 }}
            >
              <span
                className="w-2 h-2 rounded-full shrink-0"
                style={{ backgroundColor: reg.cor }}
              />
              {formatLabel(reg.id)}
            </motion.button>
          )
        })}
      </div>
    </div>
  )
}

function buildRegionPath(ufs: UFDot[]): string {
  // Ordena os pontos por ângulo em torno do centroide para criar um polígono convexo
  const cx = ufs.reduce((s, u) => s + u.cx, 0) / ufs.length
  const cy = ufs.reduce((s, u) => s + u.cy, 0) / ufs.length

  const sorted = [...ufs].sort((a, b) => {
    const angleA = Math.atan2(a.cy - cy, a.cx - cx)
    const angleB = Math.atan2(b.cy - cy, b.cx - cx)
    return angleA - angleB
  })

  return 'M' + sorted.map((u) => `${u.cx},${u.cy}`).join(' L') + ' Z'
}
