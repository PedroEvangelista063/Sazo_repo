import { useState, useCallback, type FormEvent } from 'react'
import { MapPin, Search } from 'lucide-react'
import { useUserStore } from '../store/useUserStore'
import { usePrefetchSazonalidade } from '../hooks/useSazonalidade'
import { useMunicipios } from '../hooks/useMunicipios'
import { UF_LIST } from '../types'

export function LocationSelector() {
  const { uf, municipio, setUf, setMunicipio, setLocation } = useUserStore()
  const [localUf, setLocalUf] = useState(uf ?? '')
  const [localCity, setLocalCity] = useState(municipio ?? '')
  const prefetch = usePrefetchSazonalidade()

  const { municipios } = useMunicipios(
    localUf.length === 2 ? localUf : null,
  )
  const hasSavedLocation = !!uf && !!municipio

  const doPrefetch = useCallback(
    (city: string) => {
      const trimmedUf = localUf.toUpperCase().trim()
      if (trimmedUf.length === 2 && city.trim().length >= 3) {
        prefetch(trimmedUf, city.trim())
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

  const handleCityChange = useCallback(
    (value: string) => {
      setLocalCity(value)
      if (value) doPrefetch(value)
    },
    [doPrefetch],
  )

  const handleDismiss = useCallback(() => {
    setLocalUf(uf ?? '')
    setLocalCity(municipio ?? '')
    setMunicipio('')
    setUf('')
    setLocation('', '')
  }, [uf, municipio, setUf, setMunicipio, setLocation])

  return (
    <div className="flex flex-col gap-6">
      {!hasSavedLocation && (
        <div className="text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-sazonal-verde-100">
            <MapPin className="h-8 w-8 text-sazonal-verde-600" />
          </div>
          <h1 className="mb-1 text-2xl font-bold text-gray-900">Quero Comprar</h1>
          <p className="text-sm text-gray-500">
            Descubra a melhor época para comprar hortigranjeiros na sua região
          </p>
        </div>
      )}

      <form onSubmit={handleSubmit} className="flex flex-col gap-3">
        <div>
          <label htmlFor="uf-select" className="mb-1 block text-xs font-medium text-gray-600">
            Estado
          </label>
          <select
            id="uf-select"
            value={localUf}
            onChange={(e) => setLocalUf(e.target.value)}
            className="w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm shadow-sm outline-none transition-colors focus:border-sazonal-verde-400 focus:ring-2 focus:ring-sazonal-verde-100"
          >
            <option value="">Selecione a UF</option>
            {UF_LIST.map((ufCode) => (
              <option key={ufCode} value={ufCode}>
                {ufCode}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label htmlFor="city-input" className="mb-1 block text-xs font-medium text-gray-600">
            Município
          </label>
          <select
            id="city-input"
            value={localCity}
            onChange={(e) => handleCityChange(e.target.value)}
            disabled={!localUf || localUf.length !== 2}
            className="w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm shadow-sm outline-none transition-colors focus:border-sazonal-verde-400 focus:ring-2 focus:ring-sazonal-verde-100 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <option value="">Selecione o município</option>
            {municipios.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        </div>

        <button
          type="submit"
          disabled={localUf.length !== 2 || !localCity.trim()}
          className="mt-1 flex items-center justify-center gap-2 rounded-lg bg-sazonal-verde-600 px-4 py-3 text-sm font-semibold text-white shadow-sm transition-colors hover:bg-sazonal-verde-700 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <Search className="h-4 w-4" />
          {hasSavedLocation ? 'Alterar Localização' : 'Ver Sazonalidade'}
        </button>
      </form>

      {hasSavedLocation && (
        <button
          type="button"
          onClick={handleDismiss}
          className="text-center text-xs text-gray-400 underline underline-offset-2 hover:text-gray-600"
        >
          Cancelar
        </button>
      )}
    </div>
  )
}
