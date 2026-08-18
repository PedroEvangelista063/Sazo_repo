'use client'

interface TopAppBarProps {
  search: string
  onSearchChange: (value: string) => void
  onClearSearch: () => void
  onCalendarClick?: () => void
}

/**
 * Cabeçalho unificado: linha de marca (Sazo Brasil + ações) e campo de busca
 * SEMPRE aberto em largura total. O botão [X] limpa a busca com haptic light.
 */
export function TopAppBar({
  search,
  onSearchChange,
  onClearSearch,
  onCalendarClick,
}: TopAppBarProps) {
  return (
    <header className="docked fixed inset-x-0 top-0 z-50 w-full rounded-b-lg bg-surface-container-low shadow-clay-dark">
      <div className="mx-auto flex w-full max-w-7xl flex-col gap-2 px-margin-mobile py-2">
        <div className="flex items-center justify-between gap-sm">
          <div className="flex items-center gap-sm">
            <div
              className="flex h-8 w-8 items-center justify-center rounded-full border border-outline-variant bg-surface-container text-sm shadow-clay-dark"
              title="Filtro Nacional"
            >
              🇧🇷
            </div>
            <h1 className="font-display-lg text-display-lg tracking-tight text-primary">
              Sazo Brasil
            </h1>
          </div>
          <div className="flex items-center gap-sm">
            {onCalendarClick && (
              <button
                className="clay-card flex min-h-11 w-11 items-center justify-center rounded-full p-2 text-on-surface-variant transition-transform duration-150 ease-out hover:scale-105 active:scale-95"
                onClick={onCalendarClick}
                title="Selecionar Mês"
              >
                <span
                  className="material-symbols-outlined"
                  style={{ fontVariationSettings: "'FILL' 0" }}
                >
                  calendar_month
                </span>
              </button>
            )}
          </div>
        </div>

        <div className="relative w-full">
          <span
            className="material-symbols-outlined pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-on-surface-variant"
            aria-hidden="true"
          >
            search
          </span>
          <input
            type="text"
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
            placeholder="Buscar alimento (ex: Maçã, Arroz)..."
            aria-label="Buscar alimento"
            className="h-12 w-full rounded-full border border-outline-variant bg-surface-container-lowest pl-10 pr-12 text-base text-on-surface shadow-clay-dark outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/30"
          />
          {search.length > 0 && (
            <button
              type="button"
              onClick={onClearSearch}
              aria-label="Limpar busca"
              className="absolute right-1.5 top-1/2 flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full text-on-surface-variant transition-colors hover:bg-surface-container hover:text-on-surface active:scale-90"
            >
              <span className="material-symbols-outlined text-lg">close</span>
            </button>
          )}
        </div>
      </div>
    </header>
  )
}
