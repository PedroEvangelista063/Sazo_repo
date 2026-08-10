import { useState } from 'react'

interface CategoryAccordionProps {
  emoji?: string
  title: string
  children?: React.ReactNode
  defaultOpen?: boolean
}

export function CategoryAccordion({
  emoji,
  title,
  children,
  defaultOpen = false,
}: CategoryAccordionProps) {
  const [isOpen, setIsOpen] = useState(defaultOpen)
  return (
    <div className="clay-card overflow-hidden">
      <button
        className="flex w-full items-center justify-between bg-surface-container-low p-md transition-colors hover:bg-surface-bright active:scale-95"
        onClick={() => setIsOpen(!isOpen)}
      >
        <div className="flex items-center gap-md">
          {emoji && <span className="text-2xl">{emoji}</span>}
          <span className="font-headline-md text-headline-md text-on-surface">{title}</span>
        </div>
        <span
          className="material-symbols-outlined transition-transform"
          style={{ transform: isOpen ? 'rotate(180deg)' : 'rotate(0)' }}
        >
          expand_more
        </span>
      </button>
      {isOpen && <div className="hide-scrollbar overflow-x-auto p-md">{children}</div>}
    </div>
  )
}
