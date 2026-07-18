import type { SVGProps } from 'react';
import type { ComponentType } from 'react';
import type { BRStateUF } from './types';
import { validateStateUF, normalizeStateUF } from './utils';
import { getStateName } from './i18n';

// Type alias for flag component
export type FlagComponent = ComponentType<SVGProps<SVGSVGElement>>;

// Import all flag components
import AC from './flags/AC';
import AL from './flags/AL';
import AM from './flags/AM';
import AP from './flags/AP';
import BA from './flags/BA';
import CE from './flags/CE';
import DF from './flags/DF';
import ES from './flags/ES';
import GO from './flags/GO';
import MA from './flags/MA';
import MG from './flags/MG';
import MS from './flags/MS';
import MT from './flags/MT';
import PA from './flags/PA';
import PB from './flags/PB';
import PE from './flags/PE';
import PI from './flags/PI';
import PR from './flags/PR';
import RJ from './flags/RJ';
import RN from './flags/RN';
import RO from './flags/RO';
import RR from './flags/RR';
import RS from './flags/RS';
import SC from './flags/SC';
import SE from './flags/SE';
import SP from './flags/SP';
import TO from './flags/TO';

// Map of UF codes to components
export const flagComponents: Record<BRStateUF, ComponentType<SVGProps<SVGSVGElement>>> = {
  AC,
  AL,
  AM,
  AP,
  BA,
  CE,
  DF,
  ES,
  GO,
  MA,
  MG,
  MS,
  MT,
  PA,
  PB,
  PE,
  PI,
  PR,
  RJ,
  RN,
  RO,
  RR,
  RS,
  SC,
  SE,
  SP,
  TO,
};

export interface FlagProps extends Omit<SVGProps<SVGSVGElement>, 'children'> {
  /** Brazilian state UF code (e.g., "SP", "RJ", "MG") */
  uf: BRStateUF | string;
  /** Locale for accessibility label (default: "en") */
  locale?: 'en' | 'pt-BR' | 'fi';
  /** Whether to show accessibility attributes (default: true) */
  accessible?: boolean;
}

/**
 * Dynamic Flag component that renders a Brazilian state flag by UF code
 * 
 * @example
 * ```tsx
 * <Flag uf="SP" width={100} />
 * <Flag uf="rj" width={200} height={150} locale="pt-BR" />
 * ```
 */
export function Flag({ uf, locale = 'en', accessible = true, ...props }: FlagProps) {
  const normalizedUF = normalizeStateUF(uf);
  const validUF = validateStateUF(normalizedUF);
  const FlagComponent = flagComponents[validUF];
  const stateName = getStateName(validUF, locale);

  const accessibilityProps = accessible
    ? {
        'aria-label': `${stateName} flag`,
        role: 'img' as const,
        title: stateName,
      }
    : {};

  return <FlagComponent {...accessibilityProps} {...props} />;
}

