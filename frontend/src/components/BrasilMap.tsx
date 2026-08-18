import { useState } from 'react'
import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'
import type { FlowItem } from '@/types/domain'

interface BrasilMapProps {
  selectedRegion: string | null
  onRegionClick: (regionId: string) => void
  selectedUF: string | null
  onUfClick: (uf: string) => void
  fluxos?: FlowItem[]
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
  /**
   * Nome à direita do círculo (alinhado verticalmente). Usado em regiões
   * densas onde os círculos ficam muito próximos e o nome embaixo
   * cobriria o ponto da capital vizinha.
   */
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
  className,
  onUfNavigate,
  onTableNavigate,
}: BrasilMapProps) {
  const [showFluxos, setShowFluxos] = useState(false)
  const hasFluxos = fluxos && fluxos.length > 0

  const ufMap = new Map(UFS.map((u) => [u.uf, u]))

  const hasUfSelection = selectedUF !== null && selectedUF !== undefined

  const arcs =
    (hasUfSelection || showFluxos) && fluxos
      ? fluxos
          .filter((f) => {
            if (hasUfSelection) {
              // Mostra só fluxos que envolvem a UF selecionada
              return f.origem_uf === selectedUF || f.destino_uf === selectedUF
            }
            return true
          })
          .map((f) => {
            const from = ufMap.get(f.origem_uf)
            const to = ufMap.get(f.destino_uf)
            if (!from || !to || from.uf === to.uf) return null
            const isIncoming = hasUfSelection && f.destino_uf === selectedUF
            return { from, to, flow: f, isIncoming }
          })
          .filter(Boolean)
      : []

  return (
    <div
      className={cn(
        'relative mx-auto w-full',
        'max-w-[320px] sm:max-w-[420px] md:max-w-[560px] lg:max-w-[680px] xl:max-w-[800px]',
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
        <defs>
          {REGIOES.map((reg) => (
            <radialGradient key={`glow-${reg.id}`} id={`glow-${reg.id}`} cx="50%" cy="50%" r="50%">
              <stop offset="0%" stopColor={reg.cor} stopOpacity="0.35" />
              <stop offset="100%" stopColor={reg.cor} stopOpacity="0" />
            </radialGradient>
          ))}
        </defs>

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

        {/* Legendas das regiões */}
        {REGIOES.map((reg) => {
          const ufs = UFS.filter((u) => u.regiao === reg.id)
          const midX = ufs.reduce((s, u) => s + u.cx, 0) / ufs.length
          const midY = ufs.reduce((s, u) => s + u.cy, 0) / ufs.length
          const isSelected = selectedRegion === reg.id
          return (
            <motion.g
              key={reg.id}
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
                  r={220}
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
        {arcs.length > 0 && (
          <g className="pointer-events-none">
            {arcs.map((arc, idx) => {
              if (!arc) return null
              const { from, to, flow, isIncoming } = arc
              const mx = (from.cx + to.cx) / 2
              const my = (from.cy + to.cy) / 2 - 60
              const d = `M ${from.cx} ${from.cy} Q ${mx} ${my} ${to.cx} ${to.cy}`
              const cor =
                (isIncoming ?? false)
                  ? '#3B82F6' // azul — recebe
                  : '#10B981' // verde — envia
              const strokeWidth = hasUfSelection ? 6 : 4
              return (
                <g key={`arc-${flow.id}-${idx}`}>
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
                    strokeOpacity={hasUfSelection ? 0.9 : 0.7}
                    strokeLinecap="round"
                    strokeDasharray={hasUfSelection ? 'none' : '8 6'}
                    initial={{ pathLength: 0 }}
                    animate={{ pathLength: 1 }}
                    transition={{ duration: 0.8, delay: idx * 0.08, ease: 'easeInOut' }}
                  />
                </g>
              )
            })}
          </g>
        )}

        {/* Dots individuais por UF */}
        {UFS.map((uf) => {
          const reg = REGIOES_META[uf.regiao]
          const isInRegion = selectedRegion === uf.regiao
          const isDimmed = selectedRegion !== null && !isInRegion
          const isUfActive = selectedUF === uf.uf
          const dotRadius = isUfActive ? 22 : isInRegion ? 18 : 12
          const labelRadius = isUfActive ? 30 : isInRegion ? 26 : 18
          const outerGlow = isUfActive ? 35 : isInRegion ? 28 : 0

          // Nome do estado: embaixo por padrão; à direita (alinhado ao
          // círculo) em regiões densas onde os círculos ficam muito próximos.
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
              whileHover="hover"
              whileTap="tap"
              variants={{ hover: {}, tap: {} }}
            >
              {/* Área de toque transparente — garante hit area >= 44px no menor breakpoint */}
              <circle
                cx={uf.cx}
                cy={uf.cy}
                r={UF_HIT_RADIUS}
                fill="transparent"
                pointerEvents="all"
              />

              {/* Glow externo para UF selecionada */}
              {isUfActive && (
                <motion.circle
                  cx={uf.cx}
                  cy={uf.cy}
                  r={outerGlow}
                  fill={reg.cor}
                  fillOpacity={0.15}
                  initial={{ r: 30, fillOpacity: 0.3 }}
                  animate={{ r: outerGlow, fillOpacity: 0.15 }}
                  transition={{ duration: 0.3 }}
                  pointerEvents="none"
                />
              )}

              {/* Sombra */}
              <circle
                cx={uf.cx + 2}
                cy={uf.cy + 3}
                r={dotRadius}
                fill="rgba(0,0,0,0.15)"
                className="pointer-events-none"
              />

              {/* Círculo principal */}
              <motion.circle
                cx={uf.cx}
                cy={uf.cy}
                r={dotRadius}
                fill={isUfActive ? '#fff' : reg.cor}
                fillOpacity={isUfActive ? 1 : isInRegion ? 1 : 0.75}
                stroke={isUfActive ? reg.cor : isInRegion ? '#fff' : 'none'}
                strokeWidth={isUfActive ? 6 : isInRegion ? 4 : 0}
                initial={{
                  r: dotRadius,
                  fillOpacity: isUfActive ? 1 : isInRegion ? 1 : 0.75,
                }}
                animate={{
                  r: dotRadius,
                  fillOpacity: isUfActive ? 1 : isInRegion ? 1 : 0.75,
                }}
                transition={{ duration: 0.2 }}
                variants={{ hover: { r: dotRadius + 4 }, tap: { r: dotRadius + 1 } }}
                pointerEvents="none"
              />

              {/* Label UF */}
              <motion.text
                x={uf.cx}
                y={uf.cy}
                textAnchor="middle"
                dominantBaseline="central"
                fill={isUfActive ? reg.cor : '#fff'}
                fontSize={isUfActive ? 12 : isInRegion ? 10 : 8}
                fontWeight={700}
                className="pointer-events-none select-none"
                animate={{ fontSize: isUfActive ? 12 : isInRegion ? 10 : 8 }}
                transition={{ duration: 0.2 }}
              >
                {uf.uf}
              </motion.text>

              {/* Nome do estado — embaixo do círculo; à direita em regiões densas */}
              {(isUfActive || isInRegion || selectedRegion === null) && (
                <motion.text
                  x={labelX}
                  y={labelY}
                  textAnchor={labelAnchor}
                  dominantBaseline="middle"
                  fill={reg.cor}
                  className="pointer-events-none select-none"
                  fontSize={isUfActive ? 14 : 12}
                  fontWeight={isUfActive ? 700 : 500}
                  initial={
                    uf.labelRight ? { opacity: 0, x: labelX + 6 } : { opacity: 0, y: labelY - 4 }
                  }
                  animate={uf.labelRight ? { opacity: 1, x: labelX } : { opacity: 1, y: labelY }}
                  transition={{ duration: 0.15 }}
                >
                  {uf.uf === 'DF' ? 'DF' : isUfActive ? uf.nome : uf.nome.substring(0, 6)}
                </motion.text>
              )}
            </motion.g>
          )
        })}
      </svg>

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

      {/* Botão Bandeira 🇧🇷 → Tabela */}
      {onTableNavigate && (
        <button
          onClick={onTableNavigate}
          className="group absolute bottom-4 right-4 z-10 flex flex-col items-center gap-1 rounded-2xl border border-outline-variant bg-surface-container/90 p-3 shadow-clay-dark backdrop-blur-md transition-all duration-150 hover:shadow-clay-pressed active:scale-95"
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

      {/* Controles do mapa / info */}
      <div className="mt-4 flex flex-wrap items-center justify-center gap-2">
        {hasUfSelection && (
          <span className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-gray-100 px-3 py-1 text-[11px] font-medium text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
            <span className="flex items-center gap-1">
              <span className="h-2 w-2 rounded-full bg-blue-500" />
              Recebe
            </span>
            <span className="flex items-center gap-1">
              <span className="h-2 w-2 rounded-full bg-green-500" />
              Envia
            </span>
          </span>
        )}
        {hasFluxos && !hasUfSelection && (
          <motion.button
            onClick={() => setShowFluxos((v) => !v)}
            className={cn(
              'inline-flex min-h-[44px] items-center gap-1.5 rounded-full border px-4 text-[11px] font-medium transition-colors',
              showFluxos
                ? 'border-indigo-600 bg-indigo-600 text-white'
                : 'border-indigo-400 text-indigo-500',
            )}
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
          >
            <svg
              className="h-3 w-3"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path d="M5 12h14M12 5l7 7-7 7" />
            </svg>
            {showFluxos ? 'Ocultar Fluxos' : `Fluxos (${fluxos?.length ?? 0})`}
          </motion.button>
        )}
      </div>

      {/* Legenda interativa abaixo do mapa */}
      <div className="mt-2 flex flex-wrap justify-center gap-2">
        {REGIOES.map((reg) => {
          const isActive = selectedRegion === reg.id
          return (
            <motion.button
              key={reg.id}
              onClick={() => onRegionClick(reg.id)}
              className={cn(
                'inline-flex min-h-[44px] items-center gap-1.5 rounded-full px-4 text-[11px] font-medium',
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
                className="h-2 w-2 shrink-0 rounded-full"
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
