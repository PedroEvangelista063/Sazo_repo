export type BRStateUF =
  | "AC" | "AL" | "AP" | "AM" | "BA" | "CE" | "DF"
  | "ES" | "GO" | "MA" | "MT" | "MS" | "MG"
  | "PA" | "PB" | "PR" | "PE" | "PI"
  | "RJ" | "RN" | "RS" | "RO" | "RR"
  | "SC" | "SP" | "SE" | "TO";

export type BRRegion = "North" | "Northeast" | "Central-West" | "Southeast" | "South";

export type Locale = "en" | "pt-BR" | "fi";

export interface BRStateCoordinates {
  latitude: number;
  longitude: number;
}

export interface BRStateData {
  uf: BRStateUF;
  name: string;
  capital: string;
  region: BRRegion;
  coordinates: BRStateCoordinates;
  population: number;
  area: number;
  timezone: string;
  utcOffset: number;
  iso: string;
}

import type { ComponentType, SVGProps } from 'react';

/**
 * Type alias for flag component (defined here to avoid circular imports)
 */
export type FlagComponentType = ComponentType<SVGProps<SVGSVGElement>>;

/**
 * Result of resolving a flag component with its metadata.
 */
export interface FlagResolutionResult {
  /** The flag component */
  component: FlagComponentType;
  /** The viewBox string for the flag */
  viewBox: string;
  /** The validated UF code */
  uf: BRStateUF;
  /** Whether the UF code was valid */
  isValid: boolean;
}
