import { useState, useCallback, type FormEvent } from 'react'
import { MapPin, Search } from 'lucide-react'
import { useUserStore } from '../store/useUserStore'
import { usePrefetchHortifruti } from '../hooks/useHortifruti'
import { useMunicipios } from '../hooks/useMunicipios'

const UF_LIST = [
  'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO',
  'MA', 'MT', 'MS', 'MG', 'PA', 'PB', 'PR', 'PE', 'PI',
  'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO',
]

export function LocationModal() {
  const { setLocation } = useUserStore()
  const [localUf, setLocalUf] = useState('')
  const [localCity, setLocalCity] = useState('')
  const prefetch = usePrefetchHortifruti()
  const { municipios } = useMunicipios(localUf.length === 2 ? localUf : null)

  const handleCityChange = useCallback(
    (value: string) => {
      setLocalCity(value)
      if (value && localUf.length === 2) {
        prefetch(localUf, value)
      }
    },
    [localUf, prefetch],
  )

  const handleSubmit = useCallback(
    (e: FormEvent) => {
      e.preventDefault()
      const trimmedUf = localUf.toUpperCase().trim()
      const trimmedCity = localCity.trim()
      if (trimmedUf.length !== 2 || !trimmedCity) return
      setLocation(trimmedUf, trimmedCity)
    },
    [localUf, localCity, setLocation],
  )

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-sm rounded-2xl bg-white p-6 shadow-2xl">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-sazonal-verde-100">
            <MapPin className="h-8 w-8 text-sazonal-verde-600" />
          </div>
          <h2 className="text-lg font-bold text-gray-900">
            Onde você faz compras?
          </h2>
          <p className="mt-1 text-sm text-gray-500">
            Para te mostrar os melhores preços da feira, precisamos saber onde você mora.
          </p>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col gap-3">
          <div>
            <label htmlFor="modal-uf" className="mb-1 block text-xs font-medium text-gray-600">
              Estado
            </label>
            <select
              id="modal-uf"
              value={localUf}
              onChange={(e) => setLocalUf(e.target.value)}
              className="w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm shadow-sm outline-none transition-colors focus:border-sazonal-verde-400 focus:ring-2 focus:ring-sazonal-verde-100"
            >
              <option value="">Selecione a UF</option>
              {UF_LIST.map((uf) => (
                <option key={uf} value={uf}>{uf}</option>
              ))}
            </select>
          </div>

          <div>
            <label htmlFor="modal-city" className="mb-1 block text-xs font-medium text-gray-600">
              Município
            </label>
            <select
              id="modal-city"
              value={localCity}
              onChange={(e) => handleCityChange(e.target.value)}
              disabled={!localUf}
              className="w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm shadow-sm outline-none transition-colors focus:border-sazonal-verde-400 focus:ring-2 focus:ring-sazonal-verde-100 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <option value="">Selecione o município</option>
              {municipios.map((m) => (
                <option key={m} value={m}>{m}</option>
              ))}
            </select>
          </div>

          <button
            type="submit"
            disabled={localUf.length !== 2 || !localCity.trim()}
            className="mt-2 flex items-center justify-center gap-2 rounded-lg bg-sazonal-verde-600 px-4 py-3 text-sm font-semibold text-white shadow-sm transition-colors hover:bg-sazonal-verde-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <Search className="h-4 w-4" />
            Ver Sazonalidade
          </button>
        </form>
      </div>
    </div>
  )
}

interface LocationSelectorProps {
  onSuccess?: () => void
  onCancel?: () => void
}

export function LocationSelector({ onSuccess, onCancel }: LocationSelectorProps) {
  const { uf, municipio, setUf, setMunicipio, clearLocation } = useUserStore()
  const [localUf, setLocalUf] = useState(uf ?? '')
  const [localCity, setLocalCity] = useState(municipio ?? '')
  const prefetch = usePrefetchHortifruti()
  const { municipios } = useMunicipios(localUf.length === 2 ? localUf : null)

  const handleCityChange = useCallback(
    (value: string) => {
      setLocalCity(value)
      if (value && localUf.length === 2) {
        prefetch(localUf, value)
      }
    },
    [localUf, prefetch],
  )

  const handleSubmit = useCallback(
    (e: FormEvent) => {
      e.preventDefault()
      const trimmedUf = localUf.toUpperCase().trim()
      const trimmedCity = localCity.trim()
      if (trimmedUf.length !== 2 || !trimmedCity) return
      setUf(trimmedUf)
      setMunicipio(trimmedCity)
      onSuccess?.()
    },
    [localUf, localCity, setUf, setMunicipio, onSuccess],
  )

  const handleCancel = useCallback(() => {
    if (onCancel) {
      onCancel()
    } else {
      clearLocation()
    }
  }, [onCancel, clearLocation])

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-3">
      <div>
        <label htmlFor="sel-uf" className="mb-1 block text-xs font-medium text-gray-600">
          Estado
        </label>
        <select
          id="sel-uf"
          value={localUf}
          onChange={(e) => setLocalUf(e.target.value)}
          className="w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm shadow-sm outline-none transition-colors focus:border-sazonal-verde-400 focus:ring-2 focus:ring-sazonal-verde-100"
        >
          <option value="">Selecione a UF</option>
          {UF_LIST.map((uf) => (
            <option key={uf} value={uf}>{uf}</option>
          ))}
        </select>
      </div>

      <div>
        <label htmlFor="sel-city" className="mb-1 block text-xs font-medium text-gray-600">
          Município
        </label>
        <select
          id="sel-city"
          value={localCity}
          onChange={(e) => handleCityChange(e.target.value)}
          disabled={!localUf}
          className="w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm shadow-sm outline-none transition-colors focus:border-sazonal-verde-400 focus:ring-2 focus:ring-sazonal-verde-100 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <option value="">Selecione o município</option>
          {municipios.map((m) => (
            <option key={m} value={m}>{m}</option>
          ))}
        </select>
      </div>

      <div className="flex gap-2">
        <button
          type="submit"
          disabled={localUf.length !== 2 || !localCity.trim()}
          className="flex-1 rounded-lg bg-sazonal-verde-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition-colors hover:bg-sazonal-verde-700 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Confirmar
        </button>
        {onCancel && (
          <button
            type="button"
            onClick={handleCancel}
            className="rounded-lg px-4 py-2.5 text-sm text-gray-500 transition-colors hover:bg-gray-100"
          >
            Voltar
          </button>
        )}
      </div>
    </form>
  )
}
