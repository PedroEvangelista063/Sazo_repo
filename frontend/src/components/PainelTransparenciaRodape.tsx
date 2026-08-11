import { useEffect, useState } from 'react'
import { Zap } from 'lucide-react'
import {
  getTransparency,
  subscribeTransparency,
  type TransparencyState,
} from '@/services/transparencyStore'

/** Formata ISO8601 → "DD/MM/AAAA às HH:MM" (horário local). */
function formatarDataHora(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const dd = String(d.getDate()).padStart(2, '0')
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const hh = String(d.getHours()).padStart(2, '0')
  const min = String(d.getMinutes()).padStart(2, '0')
  return `${dd}/${mm}/${d.getFullYear()} às ${hh}:${min}`
}

/**
 * Rodapé global de transparência dos dados.
 *
 * Lê o header `X-Last-Refresh` (último refresh da MV) e exibe
 * "Última atualização dos dados: DD/MM/AAAA às HH:MM". Quando o header
 * `X-Cache-Status` retorna HIT, adiciona um indicador discreto ⚡ "cache".
 */
export function PainelTransparenciaRodape() {
  const [state, setState] = useState<TransparencyState>(getTransparency)

  useEffect(() => subscribeTransparency(setState), [])

  if (!state.lastRefresh) return null

  const dataFormatada = formatarDataHora(state.lastRefresh)
  if (!dataFormatada) return null

  const emCache = state.cacheStatus === 'HIT'

  return (
    <div className="bg-[var(--bg-header)]/70 relative z-10 border-t border-gray-200/60 py-1.5 backdrop-blur-sm dark:border-gray-700/60">
      <div className="mx-auto flex max-w-5xl items-center justify-center gap-1.5 px-4">
        <span className="text-[10px] tracking-tight text-gray-400 dark:text-gray-500">
          Última atualização dos dados: {dataFormatada}
        </span>
        {emCache && (
          <span
            role="status"
            aria-label="Navegação otimizada em cache (HIT)"
            title="Navegação otimizada em cache (HIT)"
            className="inline-flex items-center gap-0.5 text-[10px] font-medium text-amber-600 dark:text-amber-400"
          >
            <Zap size={10} strokeWidth={2.2} aria-hidden="true" />
            cache
          </span>
        )}
      </div>
    </div>
  )
}
