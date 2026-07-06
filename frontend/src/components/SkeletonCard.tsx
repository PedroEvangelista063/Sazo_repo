import { Skeleton } from '@mantine/core'

export function SkeletonCard() {
  return (
    <div>
      <Skeleton height={80} width={80} radius="50%" mx="auto" mb="sm" />
      <Skeleton height={14} width="60%" mx="auto" mb={6} />
      <Skeleton height={12} width="40%" mx="auto" />
    </div>
  )
}
