import { motion } from 'framer-motion'
import { cn } from '@/lib/utils'

interface BrasilMapProps {
  selectedRegion: string | null
  onRegionClick: (regionId: string) => void
  className?: string
}

interface RegionShape {
  id: string
  label: string
  d: string
}

const REGIONS: RegionShape[] = [
  {
    id: 'norte',
    label: 'Norte',
    d: 'M95,95 L130,65 L170,55 L220,50 L280,55 L340,65 L375,85 L385,105 L375,120 L355,135 L340,150 L320,165 L290,175 L255,185 L220,190 L185,190 L155,180 L130,160 L105,140 L85,120 Z',
  },
  {
    id: 'nordeste',
    label: 'Nordeste',
    d: 'M375,85 L420,95 L445,115 L460,140 L465,165 L458,190 L445,210 L425,225 L400,235 L380,240 L355,238 L340,225 L330,210 L320,195 L310,180 L300,165 L290,175 L320,165 L340,150 L355,135 Z',
  },
  {
    id: 'centro-oeste',
    label: 'Centro-Oeste',
    d: 'M185,190 L220,190 L255,185 L290,175 L300,165 L310,180 L320,195 L330,210 L340,225 L340,240 L335,255 L320,270 L300,280 L275,285 L250,280 L225,270 L205,255 L190,235 L180,215 Z',
  },
  {
    id: 'sudeste',
    label: 'Sudeste',
    d: 'M250,280 L275,285 L300,280 L320,270 L335,255 L340,240 L355,238 L380,240 L395,250 L405,268 L400,290 L385,308 L360,318 L330,325 L300,320 L275,310 L255,295 Z',
  },
  {
    id: 'sul',
    label: 'Sul',
    d: 'M250,280 L255,295 L275,310 L300,320 L330,325 L320,340 L305,358 L285,372 L260,380 L240,378 L220,365 L200,345 L190,325 L195,300 L210,285 L230,275 Z',
  },
]

const REGION_COLORS: Record<string, { fill: string; stroke: string }> = {
  norte: {
    fill: 'fill-emerald-500/60 dark:fill-emerald-600/40',
    stroke: 'stroke-emerald-600 dark:stroke-emerald-400',
  },
  nordeste: {
    fill: 'fill-sky-500/60 dark:fill-sky-600/40',
    stroke: 'stroke-sky-600 dark:stroke-sky-400',
  },
  'centro-oeste': {
    fill: 'fill-amber-500/60 dark:fill-amber-600/40',
    stroke: 'stroke-amber-600 dark:stroke-amber-400',
  },
  sudeste: {
    fill: 'fill-rose-500/60 dark:fill-rose-600/40',
    stroke: 'stroke-rose-600 dark:stroke-rose-400',
  },
  sul: {
    fill: 'fill-violet-500/60 dark:fill-violet-600/40',
    stroke: 'stroke-violet-600 dark:stroke-violet-400',
  },
}

export function BrasilMap({ selectedRegion, onRegionClick, className }: BrasilMapProps) {
  return (
    <div className={cn('relative w-full max-w-[400px] mx-auto', className)}>
      <svg
        viewBox="0 0 500 450"
        className="w-full h-auto"
        xmlns="http://www.w3.org/2000/svg"
        role="img"
        aria-label="Mapa do Brasil por regiões"
      >
        {REGIONS.map((region) => {
          const isSelected = selectedRegion === region.id
          const colors = REGION_COLORS[region.id]
          return (
            <motion.g
              key={region.id}
              className="cursor-pointer"
              onClick={() => onRegionClick(region.id)}
              whileHover={{ scale: 1.03 }}
              whileTap={{ scale: 0.97 }}
              initial={false}
              animate={{
                filter: selectedRegion && !isSelected
                  ? 'brightness(0.6) saturate(0.3)'
                  : 'brightness(1) saturate(1)',
              }}
              transition={{ duration: 0.3 }}
              style={{ transformOrigin: 'center', transformBox: 'fill-box' }}
            >
              <motion.path
                d={region.d}
                className={cn(
                  colors.fill,
                  colors.stroke,
                  'stroke-2 transition-colors duration-300',
                  isSelected && '!fill-current drop-shadow-lg',
                )}
                initial={false}
                animate={{
                  fill: isSelected ? 'currentColor' : undefined,
                }}
                whileHover={{
                  fill: isSelected ? 'currentColor' : undefined,
                }}
              />
              <text
                x={getLabelCenter(region.id).x}
                y={getLabelCenter(region.id).y}
                textAnchor="middle"
                dominantBaseline="central"
                className={cn(
                  'fill-gray-700 dark:fill-gray-300 text-[10px] font-medium pointer-events-none',
                  isSelected && '!fill-white font-bold text-xs',
                )}
              >
                {region.label}
              </text>
            </motion.g>
          )
        })}
      </svg>
    </div>
  )
}

function getLabelCenter(id: string) {
  const centers: Record<string, { x: number; y: number }> = {
    norte: { x: 230, y: 120 },
    nordeste: { x: 400, y: 160 },
    'centro-oeste': { x: 260, y: 235 },
    sudeste: { x: 330, y: 290 },
    sul: { x: 255, y: 330 },
  }
  return centers[id] ?? { x: 200, y: 200 }
}
