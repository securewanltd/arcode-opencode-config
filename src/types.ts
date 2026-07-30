export interface PluginInput {
  client: {
    app: {
      log: (message: string, ...args: unknown[]) => void;
    };
  };
  project: unknown;
  directory: string;
  worktree: unknown;
  $: unknown;
}

export interface AgentDefinition {
  description?: string;
  mode?: "primary" | "subagent" | "all";
  model?: string;
  prompt?: string;
  temperature?: number;
  permission?: Record<string, string>;
  [key: string]: unknown;
}

export interface McpServerDefinition {
  type?: "local" | "remote";
  command?: string[];
  url?: string;
  headers?: Record<string, string>;
  environment?: Record<string, string>;
  enabled?: boolean;
  [key: string]: string | string[] | Record<string, string> | boolean | undefined;
}

export interface Config {
  agent?: Record<string, unknown>;
  mcp?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface AgentManifest {
  version: number;
  config?: Record<string, unknown>;
  agents?: Record<string, unknown>;
  mcp?: Record<string, unknown>;
}

export const ALLOWLISTED_CONFIG_KEYS = [
  "default_agent",
  "model",
  "small_model",
  "share",
  "autoupdate",
  "instructions",
] as const;

export interface PluginOptions {
  manifestUrl: string;
  token?: string;
  timeoutMs?: number;
  cacheDir?: string;
}

export interface Hooks {
  config?: (cfg: Config) => Promise<void>;
}
