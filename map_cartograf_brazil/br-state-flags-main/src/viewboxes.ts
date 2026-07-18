import type { BRStateUF } from './types';

/**
 * ViewBox metadata for all Brazilian state flags.
 * Each viewBox defines the coordinate system and aspect ratio of the flag SVG.
 */
export const FLAG_VIEWBOXES: Record<BRStateUF, string> = {
  AC: '0 0 500 350',
  AL: '0 0 175.006 116.671',
  AM: '0 0 2100 1500',
  AP: '0 0 1000 700',
  BA: '0 0 1500 1000',
  CE: '-200 -140 400 280',
  DF: '0 0 1454 1050',
  ES: '0 0 1320 924',
  GO: '0 0 560 392',
  MA: '0 0 1350 900',
  MG: '0 0 5120 3072',
  MS: '0 0 1000 700',
  MT: '0 0 2000 1400',
  PA: '0 0 900 600',
  PB: '0 0 6000 4200',
  PE: '0 0 540 360',
  PI: '0 0 750 1300',
  PR: '0 0 2500 1750',
  RJ: '-1000 -700 2000 1400',
  RN: '0 0 900 600',
  RO: '-1000 -700 2000 1400',
  RR: '0 0 2000 1200',
  RS: '-1000 -700 2000 1400',
  SC: '-418 -304 836 608',
  SE: '0 0 1000 350',
  SP: '0 0 1950 1300',
  TO: '0 0 20 14',
} as const;

