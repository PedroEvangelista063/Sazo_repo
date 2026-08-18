import { cn } from '@/lib/utils'

interface NavigationTabsProps {
  activeTab: string
  onTabChange: (tabId: string) => void
}

/**
 * Abas de navegação da visão principal.
 *
 * Todas as abas exibem ÍCONE (emoji) + TEXTO sempre visíveis — nunca há
 * colapso para ícone puro (sem max-w-0/opacity-0). Touch target >= 48px,
 * fonte >= 16px e transição tátil (active:scale-95).
 */
export function NavigationTabs({ activeTab, onTabChange }: NavigationTabsProps) {
  const tabs = [
    { id: 'mapa', label: '🗺️ Mapa' },
    { id: 'cards', label: '📄 Cards' },
    { id: 'tabela', label: '📊 Tabela' },
  ]

  return (
    <div
      className="hide-scrollbar flex w-full min-w-0 flex-none items-center gap-2 overflow-x-auto pb-1 md:flex-1 md:pb-0"
      role="tablist"
      aria-label="Modo de exibição"
    >
      {tabs.map((tab) => {
        const isActive = activeTab === tab.id
        return (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={isActive}
            onClick={() => onTabChange(tab.id)}
            className={cn(
              'flex min-h-[48px] shrink-0 items-center justify-center whitespace-nowrap rounded-full px-4',
              'text-base font-semibold transition-all duration-150 active:scale-95',
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50',
              isActive
                ? 'bg-primary text-on-primary shadow-clay-green'
                : 'bg-clay-surface text-on-surface-variant shadow-clay-rest hover:shadow-clay-pressed dark:bg-surface-container dark:text-on-surface-variant dark:shadow-clay-dark dark:hover:bg-surface-container-high',
            )}
          >
            {tab.label}
          </button>
        )
      })}
    </div>
  )
}
