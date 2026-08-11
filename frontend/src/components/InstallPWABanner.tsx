'use client'

import { useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { usePWAInstall, PWA_STORAGE_KEYS } from '@/hooks/usePWAInstall'
import { hapticLight, hapticSuccess } from '@/utils/haptics'

/**
 * A2HS install banner — fixed bottom, claymorphism, animated with Framer Motion.
 *
 * - Android/Chromium: botão primário "Instalar Aplicativo" que dispara o
 *   prompt nativo (interceptado em usePWAInstall, nunca auto-mostrado).
 * - iOS Safari: botão "Como Instalar?" que expande o passo a passo do share.
 * - Botão secundário "Agora não" + [X] persistem a dispensa no localStorage.
 * - Oculta quando não-instalável, standalone, instalado ou dispensado.
 */
export function InstallPWABanner() {
  const { canInstall, isIOS, install, dismiss } = usePWAInstall()
  const [showInstructions, setShowInstructions] = useState(false)

  const handleInstall = async () => {
    hapticLight()
    await install()
    // install() persiste o desfecho no localStorage antes de resolver — leia
    // de volta para conhecer o userChoice sem closure obsoleta.
    let installed = false
    try {
      installed = window.localStorage.getItem(PWA_STORAGE_KEYS.installed) === '1'
    } catch {
      installed = false
    }
    if (installed) hapticSuccess()
  }

  const handleClose = () => {
    hapticLight()
    dismiss()
  }

  return (
    <AnimatePresence>
      {canInstall && (
        <motion.div
          initial={{ opacity: 0, y: 80 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: 80 }}
          transition={{ type: 'spring', stiffness: 300, damping: 28 }}
          className="fixed inset-x-0 bottom-0 z-50 px-margin-mobile pb-[env(safe-area-inset-bottom)]"
          role="region"
          aria-label="Instalar aplicativo"
        >
          <div className="clay-card mx-auto flex w-full max-w-md flex-col gap-md bg-surface-container-lowest/95 p-md shadow-clay-dark backdrop-blur-md">
            <div className="flex items-start justify-between gap-md">
              <p className="text-base font-medium leading-relaxed text-on-surface">
                📲 Instale o app Sazo no seu celular para acessar mais rápido e sem gastar internet.
              </p>
              <button
                onClick={handleClose}
                aria-label="Fechar aviso de instalação"
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-outline transition-colors hover:bg-surface-container hover:text-on-surface active:scale-90"
              >
                <span className="material-symbols-outlined text-lg">close</span>
              </button>
            </div>

            {isIOS ? (
              <>
                <button
                  onClick={() => {
                    hapticLight()
                    setShowInstructions((s) => !s)
                  }}
                  aria-expanded={showInstructions}
                  className="active:shadow-clay-press flex min-h-12 items-center justify-center rounded-full bg-primary px-6 font-label-sm text-on-primary shadow-clay-green transition-all hover:brightness-110 active:translate-y-[1px]"
                >
                  Como Instalar?
                </button>
                <AnimatePresence>
                  {showInstructions && (
                    <motion.div
                      initial={{ opacity: 0, height: 0 }}
                      animate={{ opacity: 1, height: 'auto' }}
                      exit={{ opacity: 0, height: 0 }}
                      transition={{ duration: 0.2 }}
                      className="overflow-hidden"
                    >
                      <div className="flex items-start gap-sm rounded-2xl bg-surface-container px-md py-md">
                        <span
                          className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary"
                          aria-hidden="true"
                        >
                          <span className="material-symbols-outlined text-[20px]">ios_share</span>
                        </span>
                        <p className="text-base leading-relaxed text-on-surface">
                          Toque no botão de Compartilhar{' '}
                          <span
                            className="material-symbols-outlined align-middle text-[20px]"
                            aria-hidden="true"
                          >
                            ios_share
                          </span>{' '}
                          na barra do navegador e escolha "Adicionar à Tela de Início"{' '}
                          <span
                            className="material-symbols-outlined align-middle text-[20px]"
                            aria-hidden="true"
                          >
                            add
                          </span>
                          .
                        </p>
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </>
            ) : (
              <button
                onClick={handleInstall}
                className="active:shadow-clay-press flex min-h-12 items-center justify-center rounded-full bg-primary px-6 font-label-sm text-on-primary shadow-clay-green transition-all hover:brightness-110 active:translate-y-[1px]"
              >
                Instalar Aplicativo
              </button>
            )}

            <button
              onClick={handleClose}
              className="flex min-h-12 items-center justify-center rounded-full px-4 text-sm font-semibold text-on-surface-variant transition-colors hover:bg-surface-container hover:text-on-surface active:scale-95"
            >
              Agora não
            </button>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  )
}
