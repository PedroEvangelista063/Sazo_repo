import fs from 'fs';
import path from 'path';
import { transform } from '@svgr/core';

const INPUT_DIR = 'svgs/optimized';
const OUTPUT_DIR = 'src/flags';

fs.mkdirSync(OUTPUT_DIR, { recursive: true });

const files = fs.readdirSync(INPUT_DIR).filter(f => f.endsWith('.svg'));

(async () => {
  for (const file of files) {
    const svgCode = fs.readFileSync(path.join(INPUT_DIR, file), 'utf-8');
    const componentName = file
      .replace('.svg', '')
      .toUpperCase();

    let jsxCode = await transform(
      svgCode,
      { 
        icon: true, 
        typescript: true, 
        jsxRuntime: 'automatic',
        plugins: ['@svgr/plugin-jsx']
      },
      { componentName }
    );

    // Fix deprecated imageRendering values
    jsxCode = jsxCode.replace(/imageRendering: "optimizeQuality"/g, 'imageRendering: "auto"');

    fs.writeFileSync(path.join(OUTPUT_DIR, `${componentName}.tsx`), jsxCode);
    console.log(`Generated ${componentName}`);
  }
  console.log('All components have been generated.');
})();