import { PainelTransparenciaRodape } from '@/components/PainelTransparenciaRodape'

export function Footer() {
  return (
    <footer className="docked full-width fixed bottom-0 z-40 flex w-full flex-col border-t border-outline-variant bg-surface-container-lowest/80 opacity-100 backdrop-blur-md transition-opacity">
      <div className="flex w-full items-center justify-between px-lg py-sm">
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2 rounded-full border border-primary/20 bg-primary/10 px-3 py-1">
            <div className="h-2 w-2 animate-pulse rounded-full bg-primary"></div>
            <span className="font-label-sm text-[10px] uppercase tracking-wider text-primary">
              Painel Transparência Ativo
            </span>
          </div>
        </div>
        <div className="flex gap-4">
          <a className="font-label-sm text-label-sm text-outline hover:underline" href="#">
            Transparência
          </a>
          <a className="font-label-sm text-label-sm text-outline hover:underline" href="#">
            Metodologia
          </a>
        </div>
        <span className="hidden font-label-sm text-label-sm font-bold text-secondary sm:inline">
          Sazo Brasil
        </span>
      </div>
      <div className="flex w-full flex-wrap items-center justify-center gap-x-4 gap-y-1 border-t border-outline-variant/30 bg-surface-container/40 px-lg py-1.5">
        <span className="flex items-center gap-1 text-[10px] text-on-surface-variant">
          <span className="inline-block h-2 w-2 rounded-full bg-primary" aria-hidden="true" />
          Melhor época
        </span>
        <span className="flex items-center gap-1 text-[10px] text-on-surface-variant">
          <span
            className="inline-block h-2 w-2 rounded-full bg-secondary-container"
            aria-hidden="true"
          />
          Preço normal
        </span>
        <span className="flex items-center gap-1 text-[10px] text-on-surface-variant">
          <span
            className="inline-block h-2 w-2 rounded-full bg-tertiary-container"
            aria-hidden="true"
          />
          Fora de época
        </span>
        <span className="text-[10px] text-on-surface-variant opacity-50">|</span>
        <span className="text-[10px] text-amber-600 dark:text-amber-400">
          ⚠️ &lt; 3 UFs = cobertura reduzida
        </span>
        <span className="text-[10px] text-on-surface-variant">
          ⓘ Histórico = último ano real CONAB
        </span>
      </div>
      <PainelTransparenciaRodape />
    </footer>
  )
}
