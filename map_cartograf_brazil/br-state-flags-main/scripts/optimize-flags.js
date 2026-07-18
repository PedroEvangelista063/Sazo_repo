import fs from 'fs';
import path from 'path';
import { optimize } from 'svgo';

const RAW_DIR = 'svgs/raw';
const OUT_DIR = 'svgs/optimized';

fs.mkdirSync(OUT_DIR, { recursive: true });

const files = fs.readdirSync(RAW_DIR).filter(f => f.endsWith('.svg'));

for (const file of files) {
  const inputPath = path.join(RAW_DIR, file);
  const outputPath = path.join(OUT_DIR, file);
  const svg = fs.readFileSync(inputPath, 'utf-8');
  const result = optimize(svg, { path: inputPath });
  fs.writeFileSync(outputPath, result.data, 'utf-8');
  console.log(`Optimized ${file}`);
}
console.log('All SVG files have been optimized.');