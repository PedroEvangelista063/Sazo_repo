/**
 * useUserStore — Estado global de localização do usuário
 *
 * SRE/Frontend principles:
 * - Zustand + persist: sobrevive a crash, refresh, fechamento do browser
 * - localStorage é síncrono e não bloqueia a paint (vs IndexedDB async overhead)
 * - Único estado global do app: UF e município. Todo o resto (cache de API)
 *   é responsabilidade do TanStack Query, não do Zustand.
 * - Separation of concerns: store não importa React nem axios.
 */
import { create } from 'zustand'
import { persist, createJSONStorage } from 'zustand/middleware'

interface UserState {
  uf: string | null
  municipio: string | null
  setUf: (uf: string) => void
  setMunicipio: (municipio: string) => void
  setLocation: (uf: string, municipio: string) => void
  clearLocation: () => void
}

export const useUserStore = create<UserState>()(
  persist(
    (set) => ({
      uf: null,
      municipio: null,
      setUf: (uf) => set({ uf }),
      setMunicipio: (municipio) => set({ municipio }),
      setLocation: (uf, municipio) => set({ uf, municipio }),
      clearLocation: () => set({ uf: null, municipio: null }),
    }),
    {
      name: 'qcomprar-user',
      storage: createJSONStorage(() => localStorage),
      version: 1,
      migrate: (persistedState: unknown, version: number) => {
        if (version === 0) {
          return { uf: null, municipio: null }
        }
        return persistedState as { uf: string | null; municipio: string | null }
      },
      partialize: (state) => ({ uf: state.uf, municipio: state.municipio }),
    },
  ),
)
