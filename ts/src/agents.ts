// agents.ts — Agent definitions: prompts, models, tools

import type { Phase } from "./types.js";

export const BASE_TOOLS = [
  "Bash",
  "Read",
  "Edit",
  "Write",
  "Glob",
  "Grep",
  "Agent",
  "WebSearch",
  "WebFetch",
];

export interface AgentDef {
  model: "opus" | "sonnet";
  tools: string[];
  restrictions?: string[]; // tools to remove from BASE_TOOLS
}

export const AGENT_DEFS: Record<Phase, AgentDef> = {
  planning: {
    model: "opus",
    tools: [...BASE_TOOLS],
  },
  implementation: {
    model: "opus",
    tools: [...BASE_TOOLS],
  },
  verification: {
    model: "opus",
    tools: BASE_TOOLS.filter((t) => !["Edit", "Write"].includes(t)),
  },
};

export function getToolsForPhase(phase: Phase): string[] {
  return AGENT_DEFS[phase].tools;
}

export function getModelForPhase(phase: Phase): "opus" | "sonnet" {
  return AGENT_DEFS[phase].model;
}

// Staleness thresholds per phase (seconds)
export function getStalenessThreshold(_phase: Phase): number {
  return 300; // 5 minutes for all phases
}
