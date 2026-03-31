// types.ts — All TypeScript types for the software factory

export type Phase = "planning" | "implementation" | "verification";

export type PhaseStatus = "pending" | "in_progress" | "completed" | "failed";

export type GateName = "plan" | "implementation" | "verification";

export interface PhaseState {
  status: PhaseStatus;
  session_id: string;
  iterations: number;
  started_at: string;
  completed_at: string;
}

export interface ImplementationPhaseState extends PhaseState {
  tasks_total: number;
  tasks_completed: number;
}

export interface GateState {
  passed: boolean;
  feedback: string;
  evaluated_at: string;
}

export interface CycleDetectionEntry {
  count: number;
  feedback: string;
}

export interface Alert {
  type: string;
  message: string;
  phase: string;
  timestamp: string;
}

export interface RerouteEntry {
  from: string;
  to: string;
  task_id?: string;
  reason: string;
  suggestion?: string;
}

export interface FactoryState {
  factory_version: string;
  spec_file: string;
  project_dir: string;
  current_phase: Phase | "done";
  phases: {
    planning: PhaseState;
    implementation: ImplementationPhaseState;
    verification: PhaseState;
  };
  gates: Record<GateName, GateState>;
  reroutes: RerouteEntry[];
  alerts: Alert[];
  cycle_detection: Record<string, CycleDetectionEntry>;
  max_iterations_per_phase: number;
  started_at: string;
  updated_at: string;
  completed_at: string;
  final_verdict: string;
}

export interface FactoryConfig {
  specInput: string;
  projectDir: string;
  factoryDir: string;
  factoryHome: string;
  maxTurns: number | undefined;
  maxIterations: number;
  phaseTimeout: number;
  factoryTimeout: number;
  apiRetryMax: number;
  apiRetryInitialWait: number;
}

export interface GateResult {
  passed: boolean;
  feedback: string;
}

export interface RunPhaseResult {
  sessionId: string;
  isApiError: boolean;
}

export interface SpecPreviewConfig {
  enabled?: boolean;
  frontendPort?: number;
  backendPort?: number;
}

export interface SpecConstraints {
  max_iterations?: number;
  max_turns_per_phase?: number;
  target_branch?: string;
  ci_command?: string;
}

export interface Spec {
  name: string;
  description: string;
  product?: string;
  pattern?: string;
  entity?: string;
  fields?: Array<{
    name: string;
    kind: string;
    values?: string[];
    required?: boolean;
    sensitive?: boolean;
    default?: unknown;
  }>;
  permissions?: string;
  audit?: boolean;
  integrations?: string[];
  ui?: {
    list?: boolean;
    detail?: boolean;
    form?: boolean;
    search?: boolean;
    export?: boolean;
  };
  constraints?: SpecConstraints;
  preview?: SpecPreviewConfig;
}

export const PHASE_ORDER: Phase[] = [
  "planning",
  "implementation",
  "verification",
];

// Gate name mapping: phase -> gate key
export const PHASE_TO_GATE: Record<Phase, GateName> = {
  planning: "plan",
  implementation: "implementation",
  verification: "verification",
};

export const STACK = {
  runtime: "bun",
  language: "typescript",
  framework: "nextjs",
  router: "app-router",
  database: "sqlite",
  orm: "drizzle",
  driver: "better-sqlite3",
  ui: "shadcn",
  styling: "tailwind",
  animations: "motion",
  fonts: { sans: "inter", mono: "jetbrains-mono" },
  icons: "lucide",
  testing: { unit: "vitest", e2e: "playwright" },
  packageManager: "bun",
} as const;
