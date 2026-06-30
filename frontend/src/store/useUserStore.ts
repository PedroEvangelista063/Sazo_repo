import { create } from 'zustand'
import { persist, createJSONStorage } from 'zustand/middleware'
import { get, set, del } from 'idb-keyval'

interface UserState {
  selectedProducts: string[]
  selectedMonth: string | null
  addProduct: (product: string) => void
  removeProduct: (product: string) => void
  setSelectedMonth: (month: string | null) => void
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
      selectedProducts: [],
      selectedMonth: null,

      addProduct: (product) => {
        const cleaned = product.trim()
        if (!cleaned) return
        const current = get().selectedProducts
        if (current.includes(cleaned)) return
        set({ selectedProducts: [...current, cleaned] })
      },

      removeProduct: (product) => {
        set({ selectedProducts: get().selectedProducts.filter((p) => p !== product) })
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
      version: 5,
      migrate: (persisted) => {
        const old = persisted as Record<string, unknown>
        return {
          selectedProducts: Array.isArray(old.selectedProducts) ? old.selectedProducts : [],
          selectedMonth: typeof old.selectedMonth === 'string' ? old.selectedMonth : null,
        } as UserState
      },
      partialize: (state) => ({
        selectedProducts: state.selectedProducts,
        selectedMonth: state.selectedMonth,
      }),
    },
  ),
)
