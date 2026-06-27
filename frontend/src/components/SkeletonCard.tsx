export function SkeletonCard() {
  return (
    <div className="animate-pulse-soft rounded-xl border-2 border-gray-200 bg-white p-4 shadow-sm">
      <div className="mx-auto mb-3 h-20 w-20 rounded-full bg-gray-200" />
      <div className="mx-auto mb-2 h-4 w-24 rounded bg-gray-200" />
      <div className="mx-auto h-3 w-32 rounded bg-gray-200" />
    </div>
  )
}
