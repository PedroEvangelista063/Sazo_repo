import { useState, useEffect } from 'react'

export function OfflineBanner() {
  const [isOffline, setIsOffline] = useState(!navigator.onLine)

  useEffect(() => {
    const handleOnline = () => setIsOffline(false)
    const handleOffline = () => setIsOffline(true)
    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [])

  if (!isOffline) return null

  return (
    <div className="bg-status-yellow fixed left-0 top-16 z-[45] flex w-full items-center justify-center gap-2 py-1 text-center font-label-sm text-on-secondary-container">
      <span className="material-symbols-outlined text-[16px]">wifi_off</span>
      <span>Modo offline. Mostrando dados em cache.</span>
    </div>
  )
}
