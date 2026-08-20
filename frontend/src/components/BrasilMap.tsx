import { useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { cn } from '@/lib/utils'
import { arcPath, buildArcs } from '@/utils/arcFlows'
import type { BuiltArc } from '@/utils/arcFlows'
import type { BoletimFlowItem, FlowItem } from '@/types/domain'

interface BrasilMapProps {
  selectedRegion: string | null
  onRegionClick: (regionId: string) => void
  selectedUF: string | null
  onUfClick: (uf: string) => void
  fluxos?: FlowItem[]
  boletimFlows?: BoletimFlowItem[]
  className?: string
  onUfNavigate?: (uf: string) => void
  onTableNavigate?: () => void
}

interface UFDot {
  uf: string
  nome: string
  regiao: string
  cx: number
  cy: number
  labelRight?: boolean
}

const REGIOES_META: Record<
  string,
  { id: string; label: string; cor: string; corClara: string; corEscura: string }
> = {
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
  { uf: 'AC', nome: 'Acre', regiao: 'norte', cx: 109.2, cy: 343.0 },
  { uf: 'AP', nome: 'Amapá', regiao: 'norte', cx: 480.0, cy: 119.4 },
  { uf: 'AM', nome: 'Amazonas', regiao: 'norte', cx: 235.3, cy: 208.4 },
  { uf: 'PA', nome: 'Pará', regiao: 'norte', cx: 511.3, cy: 175.6 },
  { uf: 'RO', nome: 'Rondônia', regiao: 'norte', cx: 258.3, cy: 363.3 },
  { uf: 'RR', nome: 'Roraima', regiao: 'norte', cx: 291.4, cy: 95.7 },
  { uf: 'TO', nome: 'Tocantins', regiao: 'norte', cx: 566.3, cy: 349.9 },

  // Nordeste
  { uf: 'AL', nome: 'Alagoas', regiao: 'nordeste', cx: 797.9, cy: 339.3, labelRight: true },
  { uf: 'BA', nome: 'Bahia', regiao: 'nordeste', cx: 698.6, cy: 403.4 },
  { uf: 'CE', nome: 'Ceará', regiao: 'nordeste', cx: 739.3, cy: 256.8 },
  { uf: 'MA', nome: 'Maranhão', regiao: 'nordeste', cx: 628.3, cy: 230.7 },
  { uf: 'PB', nome: 'Paraíba', regiao: 'nordeste', cx: 791.1, cy: 294.7, labelRight: true },
  { uf: 'PE', nome: 'Pernambuco', regiao: 'nordeste', cx: 772.1, cy: 313.4, labelRight: true },
  { uf: 'PI', nome: 'Piauí', regiao: 'nordeste', cx: 671.2, cy: 297.6 },
  {
    uf: 'RN',
    nome: 'Rio Grande do Norte',
    regiao: 'nordeste',
    cx: 800.9,
    cy: 266.5,
    labelRight: true,
  },
  { uf: 'SE', nome: 'Sergipe', regiao: 'nordeste', cx: 781.1, cy: 364.8 },

  // Centro-Oeste
  { uf: 'DF', nome: 'Distrito Federal', regiao: 'centro-oeste', cx: 573.9, cy: 469.6 },
  { uf: 'GO', nome: 'Goiás', regiao: 'centro-oeste', cx: 548.6, cy: 467.6 },
  { uf: 'MS', nome: 'Mato Grosso do Sul', regiao: 'centro-oeste', cx: 420.2, cy: 563.0 },
  { uf: 'MT', nome: 'Mato Grosso', regiao: 'centro-oeste', cx: 419.3, cy: 422.8 },

  // Sudeste
  { uf: 'ES', nome: 'Espírito Santo', regiao: 'sudeste', cx: 716.5, cy: 550.2 },
  { uf: 'MG', nome: 'Minas Gerais', regiao: 'sudeste', cx: 636.9, cy: 530.6 },
  { uf: 'RJ', nome: 'Rio de Janeiro', regiao: 'sudeste', cx: 663.4, cy: 610.3 },
  { uf: 'SP', nome: 'São Paulo', regiao: 'sudeste', cx: 576.6, cy: 620.0 },

  // Sul
  { uf: 'PR', nome: 'Paraná', regiao: 'sul', cx: 518.4, cy: 669.8, labelRight: true },
  { uf: 'RS', nome: 'Rio Grande do Sul', regiao: 'sul', cx: 473.0, cy: 770.4 },
  { uf: 'SC', nome: 'Santa Catarina', regiao: 'sul', cx: 517.7, cy: 718.5 },
]

const REGIOES = Object.values(REGIOES_META)

// Raio (unidades do viewBox) da área de toque transparente dos dots de UF.
// A 320px de largura o mapa escala ~0.32, então r=69 => diâmetro ~44px na tela.
const UF_HIT_RADIUS = 69

function formatLabel(regiaoId: string): string {
  if (regiaoId === 'centro-oeste') return 'Centro-Oeste'
  return regiaoId.charAt(0).toUpperCase() + regiaoId.slice(1)
}

export function BrasilMap({
  selectedRegion,
  onRegionClick,
  selectedUF,
  onUfClick,
  fluxos,
  boletimFlows,
  className,
  onUfNavigate,
  onTableNavigate,
}: BrasilMapProps) {
  const [regionMenuOpen, setRegionMenuOpen] = useState(false)

  const ufMap = new Map(UFS.map((u) => [u.uf, u]))

  const hasUfSelection = selectedUF !== null && selectedUF !== undefined

  const staticArcs = hasUfSelection && fluxos ? buildArcs(fluxos, ufMap, selectedUF) : []

  const boletimArcs =
    hasUfSelection && boletimFlows && boletimFlows.length > 0
      ? buildArcs(boletimFlows, ufMap, selectedUF)
      : []

  return (
    <div
      className={cn(
        'relative mx-auto w-full',
        'max-w-[360px] sm:max-w-[480px] md:max-w-[620px] lg:max-w-[760px] xl:max-w-[900px]',
        className,
      )}
    >
      <svg
        viewBox="0 0 1000 912"
        className="h-auto w-full"
        xmlns="http://www.w3.org/2000/svg"
        role="img"
        aria-label="Mapa do Brasil por estados"
      >
        {/* Background - mapa geográfico do Brasil */}
        <image
          href="/br-map.svg"
          x="0"
          y="0"
          width="1000"
          height="912"
          preserveAspectRatio="xMidYMid meet"
          opacity={0.12}
          className="pointer-events-none"
        />

        {/* Legendas das regiões — dimming */}
        {REGIOES.map((reg) => {
          const isSelected = selectedRegion === reg.id
          return (
            <motion.g
              key={reg.id}
              initial={false}
              animate={{
                opacity: selectedRegion && !isSelected ? 0.4 : 1,
              }}
              transition={{ duration: 0.3 }}
            ></motion.g>
          )
        })}

        {/* Linhas conectando dots de cada região */}
        {REGIOES.map((reg) => {
          const ufs = UFS.filter((u) => u.regiao === reg.id)
          const isSelected = selectedRegion === reg.id || selectedRegion === null
          if (ufs.length < 2) return null
          return (
            <motion.path
              key={`line-${reg.id}`}
              d={buildRegionPath(ufs)}
              fill="none"
              stroke={reg.cor}
              strokeWidth={isSelected ? 2 : 1}
              strokeOpacity={isSelected ? 0.3 : 0.1}
              strokeDasharray="8 6"
              className="pointer-events-none"
              initial={false}
              animate={{ strokeOpacity: isSelected ? 0.3 : 0.1 }}
              transition={{ duration: 0.3 }}
            />
          )
        })}

        {/* Arcos de fluxo de abastecimento */}
        {staticArcs.length > 0 && (
          <FluxArcs
            arcs={staticArcs}
            strokeWidth={hasUfSelection ? 6 : 4}
            dashed={!hasUfSelection}
          />
        )}

        {/* Arcos dos Boletins Logísticos CONAB — sem hover (purely informational) */}
        {boletimArcs.length > 0 && (
          <FluxArcs arcs={boletimArcs} strokeWidth={hasUfSelection ? 6 : 4} />
        )}

        {/* Dots individuais por UF */}
        {UFS.map((uf) => {
          const reg = REGIOES_META[uf.regiao]
          const isInRegion = selectedRegion === uf.regiao
          const isDimmed = selectedRegion !== null && !isInRegion
          const isUfActive = selectedUF === uf.uf
          const dotRadius = isUfActive ? 22 : isInRegion ? 18 : 12
          const labelRadius = isUfActive ? 30 : isInRegion ? 26 : 18

          const labelX = uf.labelRight ? uf.cx + labelRadius + 14 : uf.cx
          const labelY = uf.labelRight ? uf.cy : uf.cy + labelRadius + 18
          const labelAnchor = uf.labelRight ? 'start' : 'middle'

          return (
            <motion.g
              key={uf.uf}
              role="button"
              tabIndex={0}
              aria-label={`${uf.uf} — ${uf.nome}`}
              aria-pressed={isUfActive}
              className="cursor-pointer"
              onClick={() => onUfClick(uf.uf)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  onUfClick(uf.uf)
                }
              }}
              initial={false}
              animate={{
                opacity: isDimmed ? 0.35 : 1,
              }}
              transition={{ duration: 0.3 }}
            >
              {/* Área de toque transparente */}
              <circle
                cx={uf.cx}
                cy={uf.cy}
                r={UF_HIT_RADIUS}
                fill="transparent"
                pointerEvents="all"
              />

              {/* Sombra */}
              <circle
                cx={uf.cx + 2}
                cy={uf.cy + 3}
                r={dotRadius}
                fill="rgba(0,0,0,0.15)"
                className="pointer-events-none"
              />

              {/* Círculo principal */}
              <circle
                cx={uf.cx}
                cy={uf.cy}
                r={dotRadius}
                fill={reg.cor}
                fillOpacity={isInRegion ? 1 : 0.75}
                className="pointer-events-none"
              />

              {/* Label UF */}
              <text
                x={uf.cx}
                y={uf.cy}
                textAnchor="middle"
                dominantBaseline="central"
                fill="#fff"
                fontSize={isInRegion ? 10 : 8}
                fontWeight={700}
                className="pointer-events-none select-none"
              >
                {uf.uf}
              </text>

              {/* Nome do estado */}
              {(isInRegion || selectedRegion === null) && (
                <text
                  x={labelX}
                  y={labelY}
                  textAnchor={labelAnchor}
                  dominantBaseline="middle"
                  fill={reg.cor}
                  className="pointer-events-none select-none"
                  fontSize={12}
                  fontWeight={500}
                >
                  {uf.nome.substring(0, 6)}
                </text>
              )}
            </motion.g>
          )
        })}
      </svg>

      {/* Botão Bandeira 🇧🇷 → Tabela — canto superior direito */}
      {onTableNavigate && (
        <button
          onClick={onTableNavigate}
          className="group absolute right-4 top-4 z-10 flex flex-col items-center gap-1 rounded-2xl border border-outline-variant bg-surface-container/90 p-3 shadow-clay-dark backdrop-blur-md transition-all duration-150 hover:shadow-clay-pressed active:scale-95"
          title="Ver Tabela Nacional"
        >
          <span className="text-2xl">🇧🇷</span>
          <span className="text-[10px] font-semibold text-on-surface-variant transition-colors group-hover:text-primary">
            Tabela
          </span>
          <svg
            className="h-3 w-3 text-primary"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth={2.5}
          >
            <path d="M5 12h14M12 5l7 7-7 7" />
          </svg>
        </button>
      )}

      {/* Floating Region Filter — canto inferior esquerdo */}
      <div className="absolute bottom-4 left-4 z-10">
        <motion.button
          onClick={() => setRegionMenuOpen((v) => !v)}
          className="flex min-h-[48px] min-w-[48px] items-center justify-center rounded-2xl border border-outline-variant bg-surface-container/90 p-3 shadow-clay-dark backdrop-blur-md transition-all duration-150 hover:shadow-clay-pressed active:scale-95"
          whileHover={{ scale: 1.05 }}
          whileTap={{ scale: 0.95 }}
          aria-label="Filtrar por região"
          aria-expanded={regionMenuOpen}
        >
          <span className="text-xl">🗺️</span>
        </motion.button>

        <AnimatePresence>
          {regionMenuOpen && (
            <motion.div
              initial={{ opacity: 0, y: 8, scale: 0.95 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0, y: 8, scale: 0.95 }}
              transition={{ duration: 0.15 }}
              className="absolute bottom-16 left-0 flex flex-col gap-1.5 rounded-2xl border border-outline-variant bg-surface-container/95 p-2 shadow-clay-dark backdrop-blur-md"
            >
              {REGIOES.map((reg) => {
                const isActive = selectedRegion === reg.id
                return (
                  <motion.button
                    key={reg.id}
                    onClick={() => {
                      onRegionClick(reg.id)
                      setRegionMenuOpen(false)
                    }}
                    className={cn(
                      'flex items-center gap-2 rounded-xl px-3 py-2 text-[11px] font-medium transition-colors',
                      isActive ? 'text-white' : 'text-on-surface hover:bg-surface-container',
                    )}
                    style={{
                      backgroundColor: isActive ? reg.cor : 'transparent',
                    }}
                    whileHover={{ scale: 1.03 }}
                    whileTap={{ scale: 0.97 }}
                  >
                    <span
                      className="h-2 w-2 shrink-0 rounded-full"
                      style={{ backgroundColor: isActive ? '#fff' : reg.cor }}
                    />
                    {formatLabel(reg.id)}
                  </motion.button>
                )
              })}
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* Badge flutuante — aparece ao selecionar uma UF */}
      {selectedUF &&
        onUfNavigate &&
        (() => {
          const ufData = UFS.find((u) => u.uf === selectedUF)
          return (
            <motion.button
              key={selectedUF}
              initial={{ opacity: 0, y: 8, scale: 0.95 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0, y: 4, scale: 0.95 }}
              transition={{ duration: 0.2 }}
              onClick={() => onUfNavigate(selectedUF)}
              style={{
                position: 'absolute',
                bottom: 16,
                left: '50%',
                x: '-50%',
              }}
              className="z-10 flex min-h-[44px] items-center gap-2 whitespace-nowrap rounded-full border border-outline-variant bg-surface-container/90 px-5 text-sm font-semibold text-on-surface shadow-clay-dark backdrop-blur-md transition-all duration-150 hover:shadow-clay-pressed active:scale-95"
            >
              <span>📄</span>
              <span>Ver Cards de {ufData?.nome ?? selectedUF}</span>
              <svg
                className="h-3.5 w-3.5 text-primary"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth={2.5}
              >
                <path d="M5 12h14M12 5l7 7-7 7" />
              </svg>
            </motion.button>
          )
        })()}

      {/* Legenda de cores — receita/envio */}
      {hasUfSelection && (
        <div className="absolute bottom-4 right-4 z-10 flex items-center gap-2 rounded-full border border-outline-variant bg-surface-container/80 px-3 py-1.5 text-[11px] font-medium text-on-surface shadow-clay-dark backdrop-blur-sm">
          <span className="flex items-center gap-1">
            <span className="h-2 w-2 rounded-full bg-blue-500" />
            Recebe
          </span>
          <span className="flex items-center gap-1">
            <span className="h-2 w-2 rounded-full bg-green-500" />
            Envia
          </span>
        </div>
      )}
    </div>
  )
}

function buildRegionPath(ufs: UFDot[]): string {
  const cx = ufs.reduce((s, u) => s + u.cx, 0) / ufs.length
  const cy = ufs.reduce((s, u) => s + u.cy, 0) / ufs.length

  const sorted = [...ufs].sort((a, b) => {
    const angleA = Math.atan2(a.cy - cy, a.cx - cx)
    const angleB = Math.atan2(b.cy - cy, b.cx - cx)
    return angleA - angleB
  })

  return 'M' + sorted.map((u) => `${u.cx},${u.cy}`).join(' L') + ' Z'
}

interface FluxArcsProps<T extends { origem_uf: string; destino_uf: string }> {
  arcs: Array<BuiltArc<T>>
  strokeWidth: number
  dashed?: boolean
}

/**
 * Renderiza os arcos origem→destino do mapa. Arcos são puramente
 * informativos — sem hover/tooltip (pointer-events removidos).
 */
function FluxArcs<T extends { origem_uf: string; destino_uf: string }>({
  arcs,
  strokeWidth,
  dashed = false,
}: FluxArcsProps<T>) {
  return (
    <g className="pointer-events-none">
      {arcs.map((arc, idx) => {
        const { from, to, isIncoming } = arc
        const d = arcPath(from, to)
        const cor = isIncoming ? '#3B82F6' : '#10B981'
        return (
          <g key={`arc-${from.uf}-${to.uf}-${idx}`}>
            {/* Sombra do arco */}
            <path
              d={d}
              fill="none"
              stroke="rgba(0,0,0,0.15)"
              strokeWidth={strokeWidth + 1}
              transform="translate(0, 4)"
            />
            {/* Arco principal animado */}
            <motion.path
              d={d}
              fill="none"
              stroke={cor}
              strokeWidth={strokeWidth}
              strokeOpacity={0.9}
              strokeLinecap="round"
              strokeDasharray={dashed ? '8 6' : 'none'}
              initial={{ pathLength: 0 }}
              animate={{ pathLength: 1 }}
              transition={{ duration: 0.8, delay: idx * 0.08, ease: 'easeInOut' }}
            />
          </g>
        )
      })}
    </g>
  )
}
