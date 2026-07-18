import type { BRStateUF, FlagResolutionResult, FlagComponentType } from './types';
import type { FlagComponent } from './Flag';
import { flagComponents } from './Flag';
import { isValidStateUF, normalizeStateUF, validateStateUF } from './utils';
import { FLAG_VIEWBOXES } from './viewboxes';

/**
 * Gets a flag component for a given state UF code.
 * Returns null if the UF code is invalid.
 *
 * @param uf The state UF code (case-insensitive)
 * @returns The flag component or null if invalid
 *
 * @example
 * ```tsx
 * const Component = getFlagComponent('SP');
 * if (Component) {
 *   return <Component width={100} />;
 * }
 * ```
 */
export function getFlagComponent(uf: string): FlagComponent | null {
  const normalizedUF = normalizeStateUF(uf);
  if (!isValidStateUF(normalizedUF)) {
    return null;
  }
  return flagComponents[normalizedUF];
}

/**
 * Gets a flag component for a given state UF code.
 * Throws an error if the UF code is invalid.
 *
 * @param uf The state UF code (case-insensitive)
 * @returns The flag component
 * @throws Error if the UF code is invalid
 *
 * @example
 * ```tsx
 * const Component = requireFlagComponent('SP');
 * return <Component width={100} />;
 * ```
 */
export function requireFlagComponent(uf: string): FlagComponent {
  const normalizedUF = normalizeStateUF(uf);
  const validUF = validateStateUF(normalizedUF); // This will throw if invalid
  return flagComponents[validUF];
}

/**
 * Resolves a flag component with its metadata (component, viewBox, validation).
 * Returns null if the UF code is invalid.
 *
 * @param uf The state UF code (case-insensitive)
 * @returns The resolution result or null if invalid
 *
 * @example
 * ```tsx
 * const result = resolveFlagComponent('SP');
 * if (result) {
 *   return (
 *     <result.component
 *       viewBox={result.viewBox}
 *       width={100}
 *     />
 *   );
 * }
 * ```
 */
export function resolveFlagComponent(uf: string): FlagResolutionResult | null {
  const normalizedUF = normalizeStateUF(uf);
  if (!isValidStateUF(normalizedUF)) {
    return null;
  }
  const validUF = normalizedUF as BRStateUF;
  return {
    component: flagComponents[validUF] as FlagComponentType,
    viewBox: FLAG_VIEWBOXES[validUF],
    uf: validUF,
    isValid: true,
  };
}

// Re-export types for convenience
export type { FlagComponent } from './Flag';

