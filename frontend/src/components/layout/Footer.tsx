export function Footer() {
  return (
    <footer className="docked full-width fixed bottom-0 z-40 flex w-full items-center justify-between border-t border-outline-variant bg-surface-container-lowest/80 px-lg py-sm opacity-100 backdrop-blur-md transition-opacity">
      <div className="flex items-center gap-4">
        <div className="flex items-center gap-2 rounded-full border border-primary/20 bg-primary/10 px-3 py-1">
          <div className="h-2 w-2 animate-pulse rounded-full bg-primary"></div>
          <span className="font-label-sm text-[10px] uppercase tracking-wider text-primary">
            Painel Transparência Ativo
          </span>
        </div>
        <span className="hidden font-label-sm text-label-sm text-on-surface-variant sm:inline">
          Dados atualizados: Hoje | Cache: OK
        </span>
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
        HortiSazonal
      </span>
    </footer>
  )
}
