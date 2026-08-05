/**
 * Store mínimo de transparência da API.
 *
 * Captura os headers `X-Last-Refresh` (ISO8601 do último refresh da MV) e
 * `X-Cache-Status` (HIT | MISS) da última resposta da API, para o rodapé
 * global do painel exibir a atualidade dos dados de forma desacoplada de
 * qualquer hook/query específico.
 */
export interface TransparencyState {
  /** ISO8601 (UTC) do último refresh da MV — header X-Last-Refresh. */
  lastRefresh: string | null
  /** Status de cache da última resposta — header X-Cache-Status. */
  cacheStatus: 'HIT' | 'MISS' | null
}

type Listener = (state: TransparencyState) => void

const INITIAL_STATE: TransparencyState = { lastRefresh: null, cacheStatus: null }

const listeners = new Set<Listener>()
let state: TransparencyState = INITIAL_STATE

/** Atualiza o estado e notifica os listeners apenas se algo mudou. */
export function setTransparency(patch: Partial<TransparencyState>): void {
  const next = { ...state, ...patch }
  if (next.lastRefresh === state.lastRefresh && next.cacheStatus === state.cacheStatus) return
  state = next
  for (const listener of listeners) listener(state)
}

export function getTransparency(): TransparencyState {
  return state
}

/**
 * Assina mudanças de transparência. Emite imediatamente com o estado atual e
 * retorna uma função de unsubscribe (própria para `useEffect`).
 */
export function subscribeTransparency(listener: Listener): () => void {
  listeners.add(listener)
  listener(state)
  return () => {
    listeners.delete(listener)
  }
}
