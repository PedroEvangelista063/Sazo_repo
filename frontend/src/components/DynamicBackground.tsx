import { useState } from 'react'
import { BANDEIRAS_UF, getBandeiraUf, MAPA_BRASIL_URL } from '@/utils/bandeirasUf'
import { cn } from '@/lib/utils'

export type DynamicBackgroundViewType = 'cards' | 'grade'

/** Duração de cada bandeira no carrossel da grade (s). Ciclo total = 27 × 6s. */
const FLAG_SLIDE_SECONDS = 6

export interface DynamicBackgroundProps {
  /** UF selecionada no filtro (ex: 'SP'). Ausente/BR → sem bandeira. */
  uf?: string | null
  /** Contexto da tela: 'cards' (bandeira central) ou 'grade' (carrossel no rodapé). */
  viewType?: DynamicBackgroundViewType
  className?: string
}

/**
 * Background dinâmico em duas camadas (puramente decorativo, `aria-hidden`):
 *
 * 1. **Mapa do Brasil** — sempre visível, `z-index` baixo, cinza claro com
 *    opacidade reduzida, deslizando continuamente no eixo X
 *    (`animate-slide-horizontal`, 90s linear).
 * 2. **Bandeira(s)** — depende do contexto:
 *    - `cards`: bandeira da UF selecionada, centralizada, com `animate-flag-breathe`
 *      (opacidade 0.3↔0.8 + scale 1↔1.05 num keyframe único — duas `animate-*`
 *      no mesmo elemento não empilham no CSS).
 *    - `grade`: carrossel com crossfade (CSS puro) de **todas as 27 bandeiras**
 *      em padrão **monocromático** (grayscale), com destaque ajustado por tema
 *      (escurece no modo claro, clareia no modo noturno) e `animation-delay`
 *      negativo escalonado — sempre há uma bandeira visível no rodapé.
 *
 * A opacidade final é multiplicada pelo wrapper, mantendo a leitura do
 * conteúdo intacta. `motion-reduce` desativa o movimento (o carrossel é
 * ocultado; a bandeira das cards fica estática).
 *
 * Nota de performance: o slide usa `background-position` (exigência da spec,
 * animação 0%→100%). Não é GPU-composited e o restart 100%→0% tem um salto
 * sutil — imperceptível na opacidade 0.07 usada na camada decorativa.
 */
export function DynamicBackground({ uf, viewType = 'cards', className }: DynamicBackgroundProps) {
  // URLs de bandeiras que falharam ao carregar (evita ícone quebrado no crossfade)
  const [failed, setFailed] = useState<Record<string, boolean>>({})
  const markFailed = (url: string) => setFailed((prev) => ({ ...prev, [url]: true }))

  const bandeiraUrl = getBandeiraUf(uf)
  const showBandeira = Boolean(bandeiraUrl && uf && !failed[bandeiraUrl])

  return (
    <div
      aria-hidden="true"
      className={cn('pointer-events-none fixed inset-0 z-0 select-none overflow-hidden', className)}
    >
      {/* Camada 1 — mapa do Brasil deslizando (sempre visível) */}
      <div
        data-testid="bg-mapa"
        className="absolute inset-0 animate-slide-horizontal bg-repeat-x motion-reduce:animate-none"
        style={{
          backgroundImage: `url(${MAPA_BRASIL_URL})`,
          backgroundSize: 'auto 70%',
          backgroundPositionY: 'center',
          filter: 'grayscale(1)',
          opacity: 0.07,
        }}
      />

      {viewType === 'grade' ? (
        /* Camada 2 — grade: carrossel crossfade com TODAS as bandeiras (monocromático) */
        <div
          data-testid="bg-carrossel"
          className="absolute inset-x-0 bottom-0 flex justify-center opacity-60 motion-reduce:hidden dark:opacity-70"
        >
          <div className="relative h-24 w-36 sm:h-28 sm:w-44">
            {Object.entries(BANDEIRAS_UF).map(([sigla, url], index) =>
              !failed[url] ? (
                <img
                  key={sigla}
                  data-testid="bg-bandeira-carrossel"
                  src={url}
                  alt=""
                  loading="lazy"
                  decoding="async"
                  draggable={false}
                  onError={() => markFailed(url)}
                  // Monocromático com destaque em ambos os temas: mais escuro no
                  // modo claro (brightness < 1), mais claro no modo noturno.
                  className="absolute inset-0 h-full w-full animate-flag-cycle object-contain brightness-[0.65] contrast-125 grayscale dark:brightness-[1.6] dark:contrast-[0.9]"
                  style={{ animationDelay: `${-(index * FLAG_SLIDE_SECONDS)}s` }}
                />
              ) : null,
            )}
          </div>
        </div>
      ) : (
        /* Camada 2 — cards: bandeira da UF selecionada, centralizada */
        showBandeira && (
          <div className="absolute left-1/2 top-1/2 w-72 max-w-[85vw] -translate-x-1/2 -translate-y-1/2 opacity-15 dark:opacity-10 sm:w-96">
            <img
              data-testid="bg-bandeira"
              src={bandeiraUrl}
              alt=""
              loading="lazy"
              draggable={false}
              onError={() => bandeiraUrl && markFailed(bandeiraUrl)}
              className="h-auto w-full animate-flag-breathe rounded-lg motion-reduce:animate-none"
            />
          </div>
        )
      )}
    </div>
  )
}
