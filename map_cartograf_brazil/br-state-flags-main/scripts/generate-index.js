import fs from 'fs';
import path from 'path';

const FLAGS_DIR = 'src/flags';
const indexPath = 'src/index.ts';

const files = fs.readdirSync(FLAGS_DIR).filter(f => f.endsWith('.tsx'));

const flagExports = files
  .map(f => {
    const name = f.replace('.tsx', '');
    return `export { default as ${name} } from './flags/${name}';`;
  })
  .join('\n');

const content = `${flagExports}

// Export types
export type { BRStateUF, BRStateData, BRStateCoordinates, BRRegion, Locale } from './types';

// Export data and utilities
export { statesData, getStateData, getStatesByRegion, getAllStateUFs } from './data';

// Export i18n utilities
export { getStateName, getRegionName, getAvailableLocales, stateNames, regionNames } from './i18n';
`;

fs.writeFileSync(indexPath, content, 'utf-8');
console.log('Generated src/index.ts');
