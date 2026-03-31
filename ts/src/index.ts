// index.ts — CLI entry point for the software factory
//
// Usage:
//   bun run ts/src/index.ts <spec-or-brief> [project-dir]
//   bun run ts/src/index.ts path/to/spec.json .
//   bun run ts/src/index.ts path/to/brief.md .
//   bun run ts/src/index.ts "Add a payment methods page" .

import { resolve } from "node:path";
import { main } from "./factory.js";

const args = process.argv.slice(2);

if (args.length < 1) {
  console.error("Usage: bun run ts/src/index.ts <spec-or-brief> [project-dir]");
  console.error("");
  console.error("The spec can be:");
  console.error("  - A .json file (structured spec)");
  console.error("  - A .md or .txt file (natural language brief)");
  console.error("  - An inline string (natural language description)");
  console.error("");
  console.error("Examples:");
  console.error("  bun run ts/src/index.ts spec.json .");
  console.error("  bun run ts/src/index.ts brief.md /path/to/project");
  console.error('  bun run ts/src/index.ts "Add a hello world page" .');
  process.exit(1);
}

const specInput = args[0];
const projectDir = resolve(args[1] || ".");

main(specInput, projectDir).catch((err) => {
  console.error(`Factory crashed: ${err}`);
  process.exit(1);
});
