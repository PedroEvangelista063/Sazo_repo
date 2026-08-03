import { Skeleton } from './ui/skeleton'

export function SkeletonCard() {
  return (
    <div className="flex flex-col items-center gap-2 rounded-clay border border-gray-200 bg-white p-4 shadow-clay-card dark:border-gray-700 dark:bg-gray-800 dark:shadow-clay-dark">
      <Skeleton className="h-16 w-16 rounded-full" />
      <Skeleton className="h-4 w-3/5" />
      <Skeleton className="h-3 w-2/5" />
    </div>
  )
}
