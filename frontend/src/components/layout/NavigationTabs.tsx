interface NavigationTabsProps {
  activeTab: string
  onTabChange: (tabId: string) => void
}

export function NavigationTabs({ activeTab, onTabChange }: NavigationTabsProps) {
  const tabs = [
    { id: 'grade-sazonal', icon: 'calendar_view_month', label: 'Grade Sazonal' },
    { id: 'cards', icon: 'view_module', label: 'Cards' },
    { id: 'mapa', icon: 'map', label: 'Mapa Regional' },
  ]

  return (
    <div className="hide-scrollbar flex w-full min-w-0 flex-none items-center justify-start gap-sm overflow-x-auto pb-1 md:w-auto md:flex-1 md:pb-0">
      {tabs.map((tab) => {
        const isActive = activeTab === tab.id
        return (
          <button
            key={tab.id}
            className={`tab-btn clay-card flex h-[48px] items-center justify-center overflow-hidden whitespace-nowrap rounded-full font-label-sm text-label-sm transition-all duration-300 ease-in-out ${
              isActive ? 'active gap-2 px-4' : 'w-[48px] gap-0 px-0'
            }`}
            onClick={() => onTabChange(tab.id)}
            title={tab.label}
          >
            <span className="material-symbols-outlined shrink-0">{tab.icon}</span>
            <span
              className={`overflow-hidden transition-all duration-300 ease-in-out ${
                isActive ? 'max-w-[200px] opacity-100' : 'max-w-0 opacity-0'
              }`}
            >
              {tab.label}
            </span>
          </button>
        )
      })}
    </div>
  )
}
