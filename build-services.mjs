// Bundles @zcode/services (TS source) into a single ESM file shipped in the engine's
// node_modules. ESM keeps `import.meta` valid; the engine's CJS zcode.cjs requires it
// via node's require(esm) support (node >=22.12 / 24).
import { createRequire } from "node:module";
const require = createRequire(resolve(process.argv[2] ?? "src", "package.json"));
const { build } = require("esbuild");
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const src = resolve(process.argv[2] ?? "src");
const engine = resolve(process.argv[3] ?? `${process.env.HOME}/.zcode/local/engine`);
const outDir = resolve(engine, "node_modules/@zcode/services");
mkdirSync(outDir, { recursive: true });

await build({
  entryPoints: [resolve(src, "packages/services/src/node.ts")],
  outfile: resolve(outDir, "node.mjs"),
  bundle: true,
  format: "esm",
  platform: "node",
  target: "node22",
  // CJS deps inside the tree emit stray require() calls; give ESM output a working require.
  banner: {
    js: "import { createRequire as __ownCreateRequire } from 'node:module'; const require = __ownCreateRequire(import.meta.url);",
  },
  sourcemap: false,
  logLevel: "info",
});

writeFileSync(
  resolve(outDir, "package.json"),
  JSON.stringify({ name: "@zcode/services", version: "0.0.0-own", type: "module", exports: { "./node": "./node.mjs" } }, null, 2) + "\n",
);
console.log(`[own] services ESM bundle -> ${outDir}/node.mjs`);
