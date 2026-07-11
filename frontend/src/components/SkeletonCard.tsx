import { Skeleton } from './ui/skeleton'

export function SkeletonCard() {
  return (
    <div className="flex flex-col items-center gap-2 rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4">
      <Skeleton className="h-16 w-16 rounded-full" />
      <Skeleton className="h-4 w-3/5" />
      <Skeleton className="h-3 w-2/5" />
    </div>
  )
}
