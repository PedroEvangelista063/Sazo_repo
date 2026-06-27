import { create } from 'zustand'
import { persist, createJSONStorage } from 'zustand/middleware'
import { get, set, del } from 'idb-keyval'

const UF_VALUES = [
  'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO',
  'MA', 'MT', 'MS', 'MG', 'PA', 'PB', 'PR', 'PE', 'PI',
  'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO',
]

interface UserState {
  uf: string | null
  municipio: string | null
  isOnboarded: boolean
  selectedProducts: string[]
  selectedMonth: string | null
  setUf: (uf: string) => void
  setMunicipio: (municipio: string) => void
  setLocation: (uf: string, municipio: string) => void
  clearLocation: () => void
  addProduct: (product: string) => void
  removeProduct: (product: string) => void
  setSelectedMonth: (month: string | null) => void
}

interface PersistedState {
  uf: string | null
  municipio: string | null
  isOnboarded: boolean
  selectedProducts: string[]
  selectedMonth: string | null
}

function isValidUF(uf: string): boolean {
  return UF_VALUES.includes(uf.toUpperCase())
}

function isValidMunicipio(municipio: string): boolean {
  return typeof municipio === 'string' && municipio.trim().length >= 2
}

const idbAsStorage = {
  getItem: async (name: string): Promise<string | null> => {
    const val = await get<string>(name)
    return val ?? null
  },
  setItem: async (name: string, value: string): Promise<void> => {
    await set(name, value)
  },
  removeItem: async (name: string): Promise<void> => {
    await del(name)
  },
}

export const useUserStore = create<UserState>()(
  persist(
    (set, get) => ({
      uf: null,
      municipio: null,
      isOnboarded: false,
      selectedProducts: [],
      selectedMonth: null,

      setUf: (uf) => {
        const cleaned = uf.toUpperCase().trim()
        if (!isValidUF(cleaned)) return
        set({ uf: cleaned, municipio: null, isOnboarded: false })
      },

      setMunicipio: (municipio) => {
        const cleaned = municipio.trim()
        if (!isValidMunicipio(cleaned)) return
        const uf = get().uf
        set({ municipio: cleaned, isOnboarded: !!uf })
      },

      setLocation: (uf, municipio) => {
        const ufCleaned = uf.toUpperCase().trim()
        const munCleaned = municipio.trim()
        if (!isValidUF(ufCleaned)) return
        if (!isValidMunicipio(munCleaned)) return
        set({ uf: ufCleaned, municipio: munCleaned, isOnboarded: true })
      },

      clearLocation: () =>
        set({
          uf: null,
          municipio: null,
          isOnboarded: false,
          selectedProducts: [],
          selectedMonth: null,
        }),

      addProduct: (product) => {
        const cleaned = product.trim()
        if (!cleaned) return
        const current = get().selectedProducts
        if (current.includes(cleaned)) return
        set({ selectedProducts: [...current, cleaned] })
      },

      removeProduct: (product) => {
        set({
          selectedProducts: get().selectedProducts.filter((p) => p !== product),
        })
      },

      setSelectedMonth: (month) => {
        if (month === null) {
          set({ selectedMonth: null })
          return
        }
        const match = month.match(/^\d{4}-\d{2}$/)
        if (!match) return
        set({ selectedMonth: month })
      },
    }),
    {
      name: 'qcomprar-user',
      storage: createJSONStorage(() => idbAsStorage),
      version: 4,
      migrate: (persisted, version) => {
        const old = persisted as Record<string, unknown>
        const partial: PersistedState = {
          uf: null,
          municipio: null,
          isOnboarded: false,
          selectedProducts: [],
          selectedMonth: null,
        }
        if (old.uf && typeof old.uf === 'string') partial.uf = old.uf
        if (old.municipio && typeof old.municipio === 'string') partial.municipio = old.municipio
        if (version < 2 && partial.uf && partial.municipio) partial.isOnboarded = true
        if (version >= 2 && typeof old.isOnboarded === 'boolean') partial.isOnboarded = old.isOnboarded
        if (version >= 3 && Array.isArray(old.selectedProducts)) partial.selectedProducts = old.selectedProducts as string[]
        if (version >= 3 && typeof old.selectedMonth === 'string') partial.selectedMonth = old.selectedMonth
        return partial as unknown as UserState
      },
      partialize: (state) => ({
        uf: state.uf,
        municipio: state.municipio,
        isOnboarded: state.isOnboarded,
        selectedProducts: state.selectedProducts,
        selectedMonth: state.selectedMonth,
      }),
    },
  ),
)
