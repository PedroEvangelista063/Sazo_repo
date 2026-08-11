import { Skeleton } from './ui/skeleton'

/**
 * Skeleton com a MESMA estrutura/altura do ProductCard final (min-h-[204px],
 * mesmo padding/gaps) para CLS = 0 ao trocar loading → dados.
 */
export function SkeletonCard() {
  return (
    <div className="flex min-h-[204px] flex-col items-center justify-center gap-2 rounded-3xl bg-clay-surface p-4 shadow-clay-rest dark:bg-surface-container-low dark:shadow-clay-dark">
      <Skeleton className="h-6 w-2/3 rounded-full" />
      <Skeleton className="h-12 w-12 rounded-full" />
      <Skeleton className="h-[22px] w-4/5" />
      <Skeleton className="h-4 w-3/5" />
    </div>
  )
}
