// utils.ts — Logging, file ops, sleep

import { rename } from "node:fs/promises";
import { join } from "node:path";

// ANSI colors
const RED = "\x1b[0;31m";
const GREEN = "\x1b[0;32m";
const YELLOW = "\x1b[1;33m";
const BLUE = "\x1b[0;34m";
const NC = "\x1b[0m";

function timestamp(): string {
  const d = new Date();
  return d.toTimeString().slice(0, 8);
}

export function log(...args: unknown[]): void {
  console.log(`${BLUE}[factory ${timestamp()}]${NC}`, ...args);
}

export function logOk(...args: unknown[]): void {
  console.log(`${GREEN}[factory ${timestamp()}] OK:${NC}`, ...args);
}

export function logWarn(...args: unknown[]): void {
  console.log(`${YELLOW}[factory ${timestamp()}] WARN:${NC}`, ...args);
}

export function logErr(...args: unknown[]): void {
  console.error(`${RED}[factory ${timestamp()}] ERROR:${NC}`, ...args);
}

export async function readJson<T = unknown>(path: string): Promise<T> {
  return Bun.file(path).json() as Promise<T>;
}

export async function writeJsonAtomic(path: string, data: unknown): Promise<void> {
  const tmp = path + ".tmp";
  await Bun.write(tmp, JSON.stringify(data, null, 2) + "\n");
  await rename(tmp, path);
}

export async function touchFile(path: string): Promise<void> {
  await Bun.write(path, "");
}

export function sleep(ms: number): Promise<void> {
  return Bun.sleep(ms);
}

export async function fileExists(path: string): Promise<boolean> {
  return Bun.file(path).exists();
}

export async function fileSize(path: string): Promise<number> {
  const f = Bun.file(path);
  if (await f.exists()) {
    return f.size;
  }
  return 0;
}

export function isoNow(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function epochNow(): number {
  return Math.floor(Date.now() / 1000);
}

export function resolveFactoryDir(projectDir: string): string {
  return join(projectDir, ".factory");
}

export async function readTextFile(path: string): Promise<string> {
  const f = Bun.file(path);
  if (await f.exists()) {
    return f.text();
  }
  return "";
}

export async function findFiles(dir: string, pattern: RegExp): Promise<string[]> {
  const results: string[] = [];
  try {
    const glob = new Bun.Glob("**/*");
    for await (const entry of glob.scan({ cwd: dir })) {
      if (pattern.test(entry)) {
        results.push(join(dir, entry));
      }
    }
  } catch {
    // directory may not exist
  }
  return results;
}

export async function countFiles(dir: string, pattern: RegExp): Promise<number> {
  const files = await findFiles(dir, pattern);
  return files.length;
}
