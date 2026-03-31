// monitor/tail.ts — Stream parser (replaces factory-tail.sh)

import { join } from "node:path";
import { readJson, fileExists, readTextFile, sleep, epochNow } from "../utils.js";

const RED = "\x1b[0;31m";
const GREEN = "\x1b[0;32m";
const YELLOW = "\x1b[1;33m";
const BLUE = "\x1b[0;34m";
const CYAN = "\x1b[0;36m";
const MAGENTA = "\x1b[0;35m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const NC = "\x1b[0m";

function timestamp(): string {
  return new Date().toTimeString().slice(0, 8);
}

function renderEvent(line: string): void {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(line);
  } catch {
    return;
  }

  const type = parsed.type as string;

  if (type === "assistant") {
    const message = parsed.message as { content?: Array<Record<string, unknown>> } | undefined;
    if (!message?.content) return;

    for (const block of message.content) {
      if (block.type === "tool_use") {
        const toolName = block.name as string;
        const input = block.input as Record<string, unknown> | undefined;

        switch (toolName) {
          case "Read":
            console.log(`  ${BLUE}${timestamp()}${NC}  ${BOLD}Read${NC} ${input?.file_path || ""}`);
            break;
          case "Edit":
            console.log(`  ${YELLOW}${timestamp()}${NC}  ${BOLD}Edit${NC} ${input?.file_path || ""}`);
            break;
          case "Write":
            console.log(`  ${GREEN}${timestamp()}${NC}  ${BOLD}Write${NC} ${input?.file_path || ""}`);
            break;
          case "Bash": {
            const cmd = String(input?.command || "").split("\n")[0].slice(0, 120);
            console.log(`  ${MAGENTA}${timestamp()}${NC}  ${BOLD}Bash${NC} ${cmd}`);
            break;
          }
          case "Grep":
            console.log(
              `  ${CYAN}${timestamp()}${NC}  ${BOLD}Grep${NC} /${input?.pattern || ""}/ in ${input?.path || "."}`,
            );
            break;
          case "Glob":
            console.log(`  ${CYAN}${timestamp()}${NC}  ${BOLD}Glob${NC} ${input?.pattern || ""}`);
            break;
          case "Agent":
            console.log(
              `  ${RED}${timestamp()}${NC}  ${BOLD}Agent${NC} ${input?.description || String(input?.prompt || "").slice(0, 80)}`,
            );
            break;
          default: {
            const inputStr = input
              ? Object.entries(input)
                  .map(([k, v]) => `${k}=${String(v).slice(0, 100)}`)
                  .join(", ")
                  .slice(0, 100)
              : "";
            console.log(`  ${DIM}${timestamp()}${NC}  ${BOLD}${toolName}${NC} ${inputStr}`);
            break;
          }
        }
      } else if (block.type === "thinking") {
        const thought = String(block.thinking || "").split("\n")[0].slice(0, 200);
        if (thought) {
          console.log(`  ${DIM}${timestamp()}${NC}  ${MAGENTA}think${NC}  ${DIM}${thought}${NC}`);
        }
      } else if (block.type === "text") {
        const text = String(block.text || "");
        const firstLine = text.split("\n")[0].slice(0, 140);
        if (firstLine) {
          console.log(`  ${DIM}${timestamp()}${NC}  ${firstLine}`);
        }
      }
    }
  } else if (type === "result") {
    const isError = parsed.is_error === true;
    const durationMs = (parsed.duration_ms as number) || 0;
    const cost = parsed.total_cost_usd || 0;
    const durationDisplay = durationMs > 0 ? `${Math.floor(durationMs / 1000)}s` : "";

    if (isError) {
      const errMsg = String(parsed.result || "unknown error").slice(0, 120);
      console.log(`\n  ${RED}${timestamp()}  SESSION ERROR${NC} (${durationDisplay}): ${errMsg}\n`);
    } else {
      console.log(
        `\n  ${GREEN}${timestamp()}  SESSION COMPLETE${NC} (${durationDisplay}, $${cost})\n`,
      );
    }
  }
}

async function tail(projectDir: string): Promise<void> {
  const factoryDir = join(projectDir, ".factory");
  const stateFile = join(factoryDir, "state.json");
  const logDir = join(factoryDir, "logs");

  console.log(`${BOLD}FACTORY TAIL${NC} — live agent activity`);
  console.log(`${DIM}Watching: ${factoryDir}${NC}`);
  console.log("");

  let lastPhase = "";
  let lastSize = 0;

  while (true) {
    // Get current phase
    let currentPhase = "unknown";
    try {
      const state = await readJson<{ current_phase: string }>(stateFile);
      currentPhase = state.current_phase;
    } catch {}

    const streamFile = join(logDir, `${currentPhase}.stream`);

    // Phase changed
    if (currentPhase !== lastPhase) {
      if (lastPhase && lastPhase !== "unknown") {
        console.log("─".repeat(60));
      }
      console.log(`${BOLD}Phase: ${CYAN}${currentPhase}${NC}`);
      console.log("");
      lastPhase = currentPhase;
      lastSize = 0;
    }

    // Read new lines from stream
    if (await fileExists(streamFile)) {
      const content = await readTextFile(streamFile);
      const currentSize = Buffer.byteLength(content, "utf8");

      if (currentSize > lastSize) {
        // Get only new content
        const fullContent = await Bun.file(streamFile).text();
        const newContent = fullContent.slice(lastSize);
        const lines = newContent.split("\n").filter(Boolean);

        for (const line of lines) {
          renderEvent(line);
        }
        lastSize = currentSize;
      }
    }

    // Check for done
    if (await fileExists(join(factoryDir, "done"))) {
      console.log("");
      console.log(`${GREEN}${BOLD}FACTORY COMPLETE${NC}`);
      console.log(`${DIM}(Ctrl+C to exit)${NC}`);
      // Keep tailing for any trailing output
    }

    await sleep(1000);
  }
}

const projectDir = process.argv[2] || ".";
tail(projectDir).catch((err) => {
  console.error(`Error: ${err}`);
  process.exit(1);
});
