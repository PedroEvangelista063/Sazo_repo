import type { BRStateUF } from './types';
import { getAllStateUFs } from './data';

/**
 * Validates if a string is a valid Brazilian state UF code
 */
export function isValidStateUF(value: string): value is BRStateUF {
  const validUFs = getAllStateUFs();
  return validUFs.includes(value as BRStateUF);
}

/**
 * Validates and returns a BRStateUF, or throws an error
 */
export function validateStateUF(value: string): BRStateUF {
  if (!isValidStateUF(value)) {
    const validUFs = getAllStateUFs().join(', ');
    throw new Error(
      `Invalid state UF: "${value}". Must be one of: ${validUFs}`
    );
  }
  return value;
}

/**
 * Normalizes a state UF code to uppercase
 */
export function normalizeStateUF(value: string): string {
  return value.toUpperCase().trim();
}

