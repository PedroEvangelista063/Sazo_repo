export { default as AC } from './flags/AC';
export { default as AL } from './flags/AL';
export { default as AM } from './flags/AM';
export { default as AP } from './flags/AP';
export { default as BA } from './flags/BA';
export { default as CE } from './flags/CE';
export { default as DF } from './flags/DF';
export { default as ES } from './flags/ES';
export { default as GO } from './flags/GO';
export { default as MA } from './flags/MA';
export { default as MG } from './flags/MG';
export { default as MS } from './flags/MS';
export { default as MT } from './flags/MT';
export { default as PA } from './flags/PA';
export { default as PB } from './flags/PB';
export { default as PE } from './flags/PE';
export { default as PI } from './flags/PI';
export { default as PR } from './flags/PR';
export { default as RJ } from './flags/RJ';
export { default as RN } from './flags/RN';
export { default as RO } from './flags/RO';
export { default as RR } from './flags/RR';
export { default as RS } from './flags/RS';
export { default as SC } from './flags/SC';
export { default as SE } from './flags/SE';
export { default as SP } from './flags/SP';
export { default as TO } from './flags/TO';

// Export types
export type { BRStateUF, BRStateData, BRStateCoordinates, BRRegion, Locale, FlagResolutionResult, FlagComponentType } from './types';

// Export data and utilities
export { statesData, getStateData, getStatesByRegion, getAllStateUFs } from './data';

// Export i18n utilities
export { getStateName, getRegionName, getAvailableLocales, stateNames, regionNames } from './i18n';

// Export Flag component
export { Flag, flagComponents } from './Flag';
export type { FlagProps, FlagComponent } from './Flag';

// Export flag utility functions
export { getFlagComponent, requireFlagComponent, resolveFlagComponent } from './flag-utils';

// Export utility functions
export { isValidStateUF, validateStateUF, normalizeStateUF } from './utils';

// Export viewBox metadata
export { FLAG_VIEWBOXES } from './viewboxes';
