// ci-simulate.ts — Multi-lang CI checker (replaces ci-simulate.sh)

import { join } from "node:path";
import { fileExists, readJson } from "./utils.js";

interface CheckResult {
  name: string;
  passed: boolean;
  output: string;
}

function runCheck(name: string, cmd: string[], cwd: string): CheckResult {
  console.log(`Running: ${name}`);
  const result = Bun.spawnSync(cmd, { cwd, stdout: "pipe", stderr: "pipe" });
  const output = result.stdout.toString() + result.stderr.toString();

  if (result.exitCode === 0) {
    return { name, passed: true, output };
  }

  console.log("  Output:");
  const lines = output.split("\n");
  for (const line of lines.slice(0, 20)) {
    console.log(`    ${line}`);
  }
  if (lines.length > 20) {
    console.log(`    ... (truncated, ${lines.length} total lines)`);
  }

  return { name, passed: false, output };
}

export async function ciSimulate(projectDir: string): Promise<{ passed: number; failed: number }> {
  console.log("=== CI Simulation ===");
  console.log(`Project: ${projectDir}`);
  console.log("");

  const results: CheckResult[] = [];

  // Node.js / TypeScript
  if (await fileExists(join(projectDir, "package.json"))) {
    console.log("Detected: Node.js project");

    // Install deps if needed
    if (
      !(await fileExists(join(projectDir, "node_modules"))) &&
      (await fileExists(join(projectDir, "package-lock.json")))
    ) {
      console.log("Installing dependencies...");
      Bun.spawnSync(["npm", "ci", "--quiet"], { cwd: projectDir, stdout: "pipe", stderr: "pipe" });
    }

    // Lint
    try {
      const pkg = await readJson<{ scripts?: Record<string, string> }>(join(projectDir, "package.json"));
      if (pkg.scripts?.lint) {
        results.push(runCheck("Lint (npm run lint)", ["npm", "run", "lint"], projectDir));
      } else if (
        (await fileExists(join(projectDir, ".eslintrc.js"))) ||
        (await fileExists(join(projectDir, ".eslintrc.json"))) ||
        (await fileExists(join(projectDir, "eslint.config.js")))
      ) {
        results.push(runCheck("Lint (npx eslint)", ["npx", "eslint", ".", "--max-warnings=0"], projectDir));
      }
    } catch {}

    // Type check
    if (await fileExists(join(projectDir, "tsconfig.json"))) {
      results.push(runCheck("TypeScript (tsc --noEmit)", ["npx", "tsc", "--noEmit"], projectDir));
    }

    // Tests
    try {
      const pkg = await readJson<{ scripts?: Record<string, string> }>(join(projectDir, "package.json"));
      if (pkg.scripts?.test) {
        results.push(runCheck("Tests (npm test)", ["npm", "test"], projectDir));
      } else if (
        (await fileExists(join(projectDir, "jest.config.js"))) ||
        (await fileExists(join(projectDir, "jest.config.ts"))) ||
        (await fileExists(join(projectDir, "vitest.config.ts")))
      ) {
        results.push(runCheck("Tests (npx vitest)", ["npx", "vitest", "run"], projectDir));
      }
    } catch {}

    // Build
    try {
      const pkg = await readJson<{ scripts?: Record<string, string> }>(join(projectDir, "package.json"));
      if (pkg.scripts?.build) {
        results.push(runCheck("Build (npm run build)", ["npm", "run", "build"], projectDir));
      }
    } catch {}
  }

  // Python
  if (
    (await fileExists(join(projectDir, "pyproject.toml"))) ||
    (await fileExists(join(projectDir, "setup.py"))) ||
    (await fileExists(join(projectDir, "requirements.txt")))
  ) {
    console.log("Detected: Python project");

    const hasRuff = Bun.spawnSync(["which", "ruff"]).exitCode === 0;
    const hasFlake8 = Bun.spawnSync(["which", "flake8"]).exitCode === 0;
    const hasMypy = Bun.spawnSync(["which", "mypy"]).exitCode === 0;
    const hasPytest = Bun.spawnSync(["which", "pytest"]).exitCode === 0;

    if (hasRuff) results.push(runCheck("Lint (ruff check)", ["ruff", "check", "."], projectDir));
    else if (hasFlake8) results.push(runCheck("Lint (flake8)", ["flake8", "."], projectDir));
    if (hasMypy) results.push(runCheck("Type check (mypy)", ["mypy", "."], projectDir));
    if (hasPytest) results.push(runCheck("Tests (pytest)", ["pytest"], projectDir));
  }

  // Go
  if (await fileExists(join(projectDir, "go.mod"))) {
    console.log("Detected: Go project");

    results.push(runCheck("Vet (go vet)", ["go", "vet", "./..."], projectDir));
    results.push(runCheck("Tests (go test)", ["go", "test", "./..."], projectDir));

    if (Bun.spawnSync(["which", "golangci-lint"]).exitCode === 0) {
      results.push(runCheck("Lint (golangci-lint)", ["golangci-lint", "run"], projectDir));
    }
  }

  // Report
  console.log("");
  console.log("=== Results ===");

  let passed = 0;
  let failed = 0;
  for (const r of results) {
    if (r.passed) {
      console.log(`  PASS: ${r.name}`);
      passed++;
    } else {
      console.log(`  FAIL: ${r.name}`);
      failed++;
    }
  }

  console.log("");
  console.log(`Passed: ${passed}, Failed: ${failed}`);

  if (failed > 0) {
    return { passed, failed };
  }

  console.log("All checks passed!");
  return { passed, failed };
}

// CLI entry
if (import.meta.main) {
  const projectDir = process.argv[2] || ".";
  const { failed } = await ciSimulate(projectDir);
  process.exit(failed > 0 ? 1 : 0);
}
