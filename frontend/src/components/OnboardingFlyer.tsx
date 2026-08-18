import { useEffect, useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'

const STORAGE_KEY = 'sazo-brasil-onboarding-dismissed'

interface FlyerExtra {
  emoji: string
  label: string
}

interface FlyerStep {
  emoji: string
  title: string
  text: string
  extra?: FlyerExtra[]
}

const STEPS: FlyerStep[] = [
  {
    emoji: '👋',
    title: 'Bem-vindo ao Sazo Brasil!',
    text: 'Aqui você descobre a melhor época para comprar frutas, verduras e legumes em cada estado. Sem valores na tela: tudo é mostrado com cores.',
  },
  {
    emoji: '🟢🟡🔴',
    title: 'As cores falam por si',
    text: 'Cada produto recebe uma cor conforme o preço da época:',
    extra: [
      { emoji: '🟢', label: 'Verde = melhor época (mais barato)' },
      { emoji: '🟡', label: 'Amarelo = preço normal' },
      { emoji: '🔴', label: 'Vermelho = fora de época (mais caro)' },
    ],
  },
  {
    emoji: '🗺️',
    title: 'Três jeitos de explorar',
    text: 'Use as abas no topo para mudar de visualização:',
    extra: [
      { emoji: '📊', label: 'Tabela = os 12 meses de cada produto' },
      { emoji: '📄', label: 'Cards = produtos um a um, com status' },
      { emoji: '🗺️', label: 'Mapa = de onde vem cada alimento (padrão)' },
    ],
  },
  {
    emoji: '🎯',
    title: 'Filtre do seu jeito',
    text: 'Toque nos círculos coloridos da barra lateral para ver só o que interessa, e escolha o estado e o mês lá em cima. Pronto para começar?',
  },
]

export function OnboardingFlyer() {
  const [open, setOpen] = useState(false)
  const [step, setStep] = useState(0)
  const [dontShowAgain, setDontShowAgain] = useState(false)

  useEffect(() => {
    let dismissed = false
    try {
      dismissed = localStorage.getItem(STORAGE_KEY) === '1'
    } catch {
      dismissed = false
    }
    if (!dismissed) {
      // Pequeno atraso para a página carregar antes do popup
      const t = window.setTimeout(() => setOpen(true), 800)
      return () => window.clearTimeout(t)
    }
  }, [])

  const finish = () => {
    if (dontShowAgain) {
      try {
        localStorage.setItem(STORAGE_KEY, '1')
      } catch {
        // armazenamento indisponível — não bloqueia o fechamento
      }
    }
    setOpen(false)
  }

  const next = () => {
    if (step < STEPS.length - 1) {
      setStep((s) => s + 1)
    } else {
      finish()
    }
  }

  const current = STEPS[step]

  return (
    <AnimatePresence>
      {open && (
        <div className="fixed inset-0 z-[120] flex items-center justify-center p-margin-mobile">
          {/* Backdrop */}
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="absolute inset-0 bg-on-background/25 backdrop-blur-sm"
            onClick={finish}
            aria-hidden="true"
          />

          {/* Flyer card */}
          <motion.div
            role="dialog"
            aria-modal="true"
            aria-label="Como usar o Sazo Brasil"
            initial={{ opacity: 0, y: 24, scale: 0.94 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 24, scale: 0.94 }}
            transition={{ type: 'spring', stiffness: 260, damping: 24 }}
            className="clay-card relative flex w-full max-w-md flex-col gap-lg overflow-hidden bg-surface-container-lowest/95 p-lg shadow-clay-dark backdrop-blur-md"
          >
            <div className="flex items-center justify-between">
              <span className="rounded-full bg-primary/10 px-3 py-1 font-label-sm text-[10px] uppercase tracking-wider text-primary">
                Guia rápido
              </span>
              <button
                onClick={finish}
                aria-label="Fechar guia"
                className="flex h-10 w-10 items-center justify-center rounded-full text-outline transition-colors hover:bg-surface-container hover:text-on-surface"
              >
                <span className="material-symbols-outlined text-lg">close</span>
              </button>
            </div>

            {/* Passo atual */}
            <AnimatePresence mode="wait">
              <motion.div
                key={step}
                initial={{ opacity: 0, x: 24 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -24 }}
                transition={{ duration: 0.18 }}
                className="flex min-h-[240px] flex-col items-center gap-md text-center"
              >
                <span className="text-5xl" aria-hidden="true">
                  {current.emoji}
                </span>
                <h2 className="font-headline-md text-headline-md text-on-surface">
                  {current.title}
                </h2>
                <p className="text-body-md text-on-surface-variant">{current.text}</p>
                {current.extra && (
                  <ul className="flex flex-col gap-2 text-left">
                    {current.extra.map((item) => (
                      <li
                        key={item.label}
                        className="rounded-clay-sm flex items-start gap-2 bg-surface-container px-3 py-2 text-label-sm text-on-surface"
                      >
                        <span aria-hidden="true">{item.emoji}</span>
                        <span>{item.label}</span>
                      </li>
                    ))}
                  </ul>
                )}
              </motion.div>
            </AnimatePresence>

            {/* Indicador de passos */}
            <div className="flex items-center justify-center gap-1.5" aria-hidden="true">
              {STEPS.map((_, i) => (
                <button
                  key={i}
                  onClick={() => setStep(i)}
                  className={`h-2 rounded-full transition-all duration-300 ${
                    i === step ? 'w-6 bg-primary' : 'w-2 bg-outline-variant'
                  }`}
                  tabIndex={-1}
                  aria-label={`Passo ${i + 1}`}
                />
              ))}
            </div>

            {/* Ações */}
            <div className="flex items-center justify-between gap-md">
              <button
                onClick={() => setStep((s) => Math.max(0, s - 1))}
                disabled={step === 0}
                className="rounded-full px-4 py-2 font-label-sm text-on-surface-variant transition-colors hover:text-on-surface disabled:opacity-30"
              >
                Voltar
              </button>
              <button
                onClick={next}
                className="active:shadow-clay-press rounded-full bg-primary px-6 py-2.5 font-label-sm text-on-primary shadow-clay-green transition-all hover:brightness-110 active:translate-y-[1px]"
              >
                {step === STEPS.length - 1 ? 'Começar 🚀' : 'Próximo'}
              </button>
            </div>

            {/* Não mostrar novamente */}
            <label className="flex cursor-pointer items-center justify-center gap-2 text-label-sm text-on-surface-variant">
              <input
                type="checkbox"
                checked={dontShowAgain}
                onChange={(e) => setDontShowAgain(e.target.checked)}
                className="h-4 w-4 rounded accent-primary"
              />
              Não mostrar novamente
            </label>
          </motion.div>
        </div>
      )}
    </AnimatePresence>
  )
}
