interface TopAppBarProps {
  onCalendarClick?: () => void
  onThemeToggle?: () => void
}

export function TopAppBar({ onCalendarClick, onThemeToggle }: TopAppBarProps) {
  return (
    <header className="docked full-width fixed top-0 z-50 flex h-16 w-full items-center justify-between rounded-b-lg bg-surface-container-low px-margin-mobile shadow-clay-dark">
      <div className="flex items-center gap-sm">
        <button
          className="clay-card flex items-center justify-center rounded-full p-2 text-on-surface-variant transition-transform duration-150 ease-out hover:scale-105 active:scale-95"
          title="Buscar"
        >
          <span className="material-symbols-outlined" style={{ fontVariationSettings: "'FILL' 0" }}>
            search
          </span>
        </button>
        <div
          className="flex h-8 w-8 items-center justify-center rounded-full border border-outline-variant bg-surface-container text-sm shadow-clay-dark"
          title="Filtro Nacional"
        >
          🇧🇷
        </div>
        <h1 className="font-display-lg text-display-lg tracking-tight text-primary">Sazo Brasil</h1>
      </div>
      <div className="flex items-center gap-sm">
        {onCalendarClick && (
          <button
            className="clay-card flex items-center justify-center rounded-full p-2 text-on-surface-variant transition-transform duration-150 ease-out hover:scale-105 active:scale-95"
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
        {onThemeToggle && (
          <button
            className="clay-card flex items-center justify-center rounded-full p-2 text-on-surface-variant transition-transform duration-150 ease-out hover:scale-105 active:scale-95"
            onClick={onThemeToggle}
            title="Alternar Tema"
          >
            <span
              className="material-symbols-outlined"
              style={{ fontVariationSettings: "'FILL' 0" }}
            >
              dark_mode
            </span>
          </button>
        )}
      </div>
    </header>
  )
}
